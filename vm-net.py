#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vm-net.py — 主机 <-> QEMU virt 虚拟机 的用户态 ICMP 网桥

为什么需要它:
  本开发容器没有 CAP_NET_ADMIN, 无法创建 TAP/网桥, 因此内核层的 ping 不可行;
  QEMU 默认 user(SLIRP) 网络只支持出站 NAT, 主机无法 ping 虚拟机。
  本网桥通过 QEMU 的 socket 网卡后端 (-netdev socket) 在用户态终结二层,
  实现最小 ARP + ICMP, 使 guest 与主机之间可以真实地互相 ping。

网络拓扑 (MAC/IP 与 build_qemu.sh 保持一致):
  guest eth0 (52:54:00:CA:FE:01) 192.168.100.2/24 <---> 本网桥 (192.168.100.1/24)
      guest 侧: ping 192.168.100.1
      主机  侧: python3 vm-net.py ping 192.168.100.2
  guest eth1 (52:54:00:CA:FE:02) 10.0.2.15/24 ----> SLIRP NAT 出网 (网关 10.0.2.2)

用法:
  python3 vm-net.py daemon                       # 网桥守护进程 (build_qemu.sh 自动拉起, 幂等)
  python3 vm-net.py ping 192.168.100.2 [-c N]    # 主机侧 ping 虚拟机 (默认 -c 4)
  python3 vm-net.py probe                        # 探测守护进程是否在位 (exit 0 = 在位)
"""
import argparse
import os
import socket
import struct
import sys
import threading
import time

QEMU_PORT = int(os.environ.get("VM_NET_QEMU_PORT", "47777"))  # QEMU 帧通道
CTRL_PORT = int(os.environ.get("VM_NET_CTRL_PORT", "47778"))  # vm-ping 控制通道
BR_IP     = os.environ.get("VM_NET_HOST_IP", "192.168.100.1")  # 网桥(主机侧) IP
BR_MAC    = bytes.fromhex("525400990001")                      # 网桥侧 MAC
GUEST_IP  = os.environ.get("VM_NET_GUEST_IP", "192.168.100.2")  # guest eth0 IP
GUEST_MAC = bytes.fromhex("525400cafe01")                      # 与 -device mac= 一致


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, file=sys.stderr, flush=True)


def ip2b(s):
    return socket.inet_aton(s)


def b2ip(b):
    return socket.inet_ntoa(b)


def csum(data):
    if len(data) & 1:
        data += b"\0"
    s = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return (~s) & 0xFFFF


def eth(dst, src, etype, payload):
    return dst + src + struct.pack("!H", etype) + payload


def ipv4(src, dst, proto, payload):
    hdr = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(payload),
                      0x1234, 0x4000, 64, proto, 0, ip2b(src), ip2b(dst))
    hdr = hdr[:10] + struct.pack("!H", csum(hdr)) + hdr[12:]
    return hdr + payload


def icmp_echo(itype, ident, seq, data):
    hdr = struct.pack("!BBHHH", itype, 0, 0, ident, seq)
    return struct.pack("!BBHHH", itype, 0, csum(hdr + data), ident, seq) + data


def parse_frame(frame):
    """解析以太网帧, 只关心 ARP 和 ICMP echo; 其余返回 None"""
    if len(frame) < 34:
        return None
    dst, src = frame[:6], frame[6:12]
    etype = struct.unpack("!H", frame[12:14])[0]
    if etype == 0x0806 and len(frame) >= 42:
        oper = struct.unpack("!H", frame[20:22])[0]
        sha, spa, tpa = frame[22:28], frame[28:32], frame[38:42]
        return ("arp", src, oper, sha, spa, tpa)
    if etype == 0x0800:
        ihl = (frame[14] & 0xF) * 4
        if len(frame) < 14 + ihl + 8 or frame[23] != 1:
            return None
        sip, dip = b2ip(frame[26:30]), b2ip(frame[30:34])
        l4 = frame[14 + ihl:]
        itype, _icode, _cksum, ident, seq = struct.unpack("!BBHHH", l4[:8])
        return ("icmp", src, sip, dip, itype, ident, seq, l4[8:])
    return None


class Bridge:
    def __init__(self):
        self.qemu = None          # 与 QEMU 的帧通道
        self.lock = threading.Lock()
        self.len_order = None     # QEMU 帧长前缀的字节序, 首帧自动探测
        self.pending = {}         # (ident, seq) -> {event, t0, rtt}
        self.plock = threading.Lock()

    # ---------------- 帧通道 ----------------
    def send_frame(self, frame):
        with self.lock:
            if self.qemu is None:
                raise ConnectionError("QEMU 未连接")
            head = struct.pack((self.len_order or "!") + "I", len(frame))
            self.qemu.sendall(head + frame)

    @staticmethod
    def _recv_exact(sock, n):
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("QEMU 断开")
            buf += chunk
        return buf

    def _read_frame(self, sock):
        head = self._recv_exact(sock, 4)
        if self.len_order is None:
            # 首帧探测 4 字节长度前缀的字节序: 合法帧长 14..2048 且 ethertype 合理
            for order in ("!", "<", ">"):
                n = struct.unpack(order + "I", head)[0]
                if 14 <= n <= 2048:
                    frame = self._recv_exact(sock, n)
                    if len(frame) >= 14 and \
                            struct.unpack("!H", frame[12:14])[0] in (0x0800, 0x0806, 0x86DD):
                        self.len_order = order
                        log("帧长前缀字节序探测结果: %s" % order)
                        return frame
            raise ConnectionError("无法识别 QEMU 帧格式")
        return self._recv_exact(sock, struct.unpack(self.len_order + "I", head)[0])

    def _handle(self, frame):
        p = parse_frame(frame)
        if not p:
            return
        if p[0] == "arp":
            _, src, oper, sha, spa, tpa = p
            if oper == 1 and b2ip(tpa) == BR_IP:
                log("ARP who-has %s tell %s -> reply(%s)" % (b2ip(tpa), b2ip(spa), BR_MAC.hex()))
                arp = struct.pack("!HHBBH", 1, 0x0800, 6, 4, 2)
                arp += BR_MAC + ip2b(BR_IP) + src + spa
                self.send_frame(eth(src, BR_MAC, 0x0806, arp))
            return
        _, src, sip, dip, itype, ident, seq, data = p
        if itype == 8 and dip == BR_IP:            # guest ping 主机 -> 网桥直接应答
            log("ICMP echo request %s(id=%d seq=%d, %d bytes) -> reply" %
                (sip, ident, seq, len(data)))
            reply = ipv4(BR_IP, sip, 1, icmp_echo(0, ident, seq, data))
            self.send_frame(eth(src, BR_MAC, 0x0800, reply))
        elif itype == 0 and sip == GUEST_IP:       # vm-ping 的 echo reply 回来了
            log("ICMP echo reply %s(id=%d seq=%d) -> vm-ping" % (sip, ident, seq))
            with self.plock:
                w = self.pending.get((ident, seq))
            if w:
                w["rtt"] = (time.time() - w["t0"]) * 1000.0
                w["event"].set()

    def serve_qemu(self):
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", QEMU_PORT))
        srv.listen(4)
        log("帧通道就绪: 127.0.0.1:%d (等待 QEMU -netdev socket 接入)" % QEMU_PORT)
        while True:
            sock, _ = srv.accept()
            with self.lock:
                if self.qemu is not None:
                    try:
                        self.qemu.close()
                    except OSError:
                        pass
                self.qemu, self.len_order = sock, None
            log("QEMU 已接入")
            try:
                while True:
                    frame = self._read_frame(sock)
                    threading.Thread(target=self._handle, args=(frame,), daemon=True).start()
            except (ConnectionError, OSError):
                pass
            with self.lock:
                if self.qemu is sock:
                    self.qemu = None
            log("QEMU 断开, 等待重连")

    # ---------------- 控制通道 (vm-ping 用) ----------------
    def _ping_once(self, ident, seq, timeout=2.0):
        w = {"event": threading.Event(), "t0": time.time(), "rtt": None}
        with self.plock:
            self.pending[(ident, seq)] = w
        try:
            payload = b"vm-net-ping" + struct.pack("!d", w["t0"])
            req = ipv4(BR_IP, GUEST_IP, 1, icmp_echo(8, ident, seq, payload))
            self.send_frame(eth(GUEST_MAC, BR_MAC, 0x0800, req))
            if not w["event"].wait(timeout):
                return None
            return w["rtt"]
        finally:
            with self.plock:
                self.pending.pop((ident, seq), None)

    def _ctrl_conn(self, conn):
        f = conn.makefile("rwb", buffering=0)
        try:
            for line in f:
                parts = line.decode(errors="replace").split()
                if not parts:
                    continue
                if parts[0] == "PING" and len(parts) >= 2:
                    ident = int(parts[1])
                    seq = int(parts[2]) if len(parts) > 2 else ident
                    try:
                        rtt = self._ping_once(ident, seq)
                    except ConnectionError:
                        conn.sendall(b"DOWN\n")
                        continue
                    out = "TIMEOUT\n" if rtt is None else "REPLY %.2f\n" % rtt
                    conn.sendall(out.encode())
                elif parts[0] == "QUIT":
                    break
        except OSError:
            pass
        finally:
            conn.close()

    def serve_ctrl(self):
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", CTRL_PORT))
        srv.listen(8)
        log("控制通道就绪: 127.0.0.1:%d (vm-ping)" % CTRL_PORT)
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=self._ctrl_conn, args=(conn,), daemon=True).start()


def cmd_daemon(_args):
    br = Bridge()
    threading.Thread(target=br.serve_ctrl, daemon=True).start()
    br.serve_qemu()          # 阻塞主线程


def cmd_probe(_args):
    try:
        s = socket.create_connection(("127.0.0.1", CTRL_PORT), timeout=1)
        s.close()
    except OSError:
        sys.exit(1)


def cmd_ping(args):
    if args.ip != GUEST_IP:
        print("vm-net 网桥只终结 guest 网卡 %s, 目标 %s 不可达" % (GUEST_IP, args.ip),
              file=sys.stderr)
        sys.exit(1)
    try:
        ctrl = socket.create_connection(("127.0.0.1", CTRL_PORT), timeout=3)
    except OSError:
        print("网桥未运行 (先执行 ./build_qemu.sh -r, 或手动: python3 %s daemon)" %
              os.path.abspath(__file__), file=sys.stderr)
        sys.exit(2)
    f = ctrl.makefile("rwb", buffering=0)
    ident = os.getpid() & 0xFFFF
    sent = received = 0
    times = []
    print("PING %s (%s) via vm-net bridge, %d bytes of data" % (args.ip, args.ip, 32))
    for i in range(1, args.count + 1):
        sent += 1
        t0 = time.time()
        f.write(("PING %d %d\n" % (ident, i)).encode())
        line = f.readline()
        if not line:
            print("网桥连接断开")
            break
        s = line.decode().strip()
        if s.startswith("REPLY"):
            rtt = float(s.split()[1])
            received += 1
            times.append(rtt)
            print("64 bytes from %s: icmp_seq=%d ttl=64 time=%.2f ms" % (args.ip, i, rtt))
        elif s == "TIMEOUT":
            print("Request timeout for icmp_seq %d" % i)
        else:
            print("icmp_seq=%d %s" % (i, s))
        time.sleep(max(0.0, 1.0 - (time.time() - t0)))
    loss = (sent - received) * 100.0 / sent if sent else 100.0
    print("--- %s ping statistics ---" % args.ip)
    if times:
        print("%d packets transmitted, %d received, %.0f%% packet loss, "
              "rtt min/avg/max = %.2f/%.2f/%.2f ms"
              % (sent, received, loss, min(times), sum(times) / len(times), max(times)))
    else:
        print("%d packets transmitted, 0 received, 100%% packet loss" % sent)
    sys.exit(0 if received else 1)


def main():
    ap = argparse.ArgumentParser(description="主机 <-> QEMU virt 用户态 ICMP 网桥")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("daemon", help="启动网桥守护进程")
    p_probe = sub.add_parser("probe", help="探测守护进程是否在位")
    p_probe.set_defaults(fn=cmd_probe)
    p_ping = sub.add_parser("ping", help="主机侧 ping 虚拟机")
    p_ping.add_argument("ip")
    p_ping.add_argument("-c", dest="count", type=int, default=4)
    p_ping.set_defaults(fn=cmd_ping)
    sub.choices["daemon"].set_defaults(fn=cmd_daemon)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
