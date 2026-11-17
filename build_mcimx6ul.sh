#!/usr/bin/env bash
# =============================================================================
# build_mcimx6ul.sh — QEMU mcimx6ul-evk (i.MX6UL / Cortex-A7) 板卡构建与运行
#
# 用法:
#   ./build_mcimx6ul.sh -b <组件>[,<组件>...]
#                                    编译指定组件, 组件取值:
#                                      rootfs  busybox(静态 armhf) + 两份 initramfs
#                                      kernel  内核 zImage + imx6ul-14x14-evk.dtb
#                                      uboot   U-Boot(mx6ul_14x14_evk) 引导产物
#                                      qemu    QEMU 11.1.3 源码编译(arm-softmmu)
#                                      all     以上四项(顺序 rootfs→kernel→uboot→qemu)
#                                    -b 可重复, 也可逗号分隔: -b kernel,rootfs
#   ./build_mcimx6ul.sh -r            启动板卡, 交互式串口 shell(exit 退出后自动重生)
#   ./build_mcimx6ul.sh -r test       验证模式: 打印 VERIFY 标记后自动关机(回归用)
#   ./build_mcimx6ul.sh -r -S -s      其余参数原样传给 qemu(例: -S -s 配合 gdb)
#   ./build_mcimx6ul.sh -c            删除构建产物(build-mcimx6ul/ 与 out-mcimx6ul/)
#   ./build_mcimx6ul.sh -h            帮助
#
# 板卡事实(与同目录 build_qemu.sh 的 aarch64 virt 环境完全不同, 勿混用):
#   machine        mcimx6ul-evk: i.MX6UL, 单核 Cortex-A7, RAM 基址 0x80000000
#   QEMU 二进制     qemu-system-arm (build_qemu.sh 用的是 qemu-system-aarch64)
#   串口           uart1 -> /dev/ttymxc0, 115200 (内核 dtb 的 stdout-path)
#   存储           只有 USDHC: 根文件系统走 initramfs 或 -drive if=sd
#                  无 NAND/QSPI 模型(GPMI 未建模, QSPI 是 unimplemented stub)
#   引导方式        本板无 i.MX BootROM、无 pflash, 因此 U-Boot 不能像 virt 那样
#                  用 -bios 引导: QEMU 的 arm_load_kernel 只对 raw 镜像按
#                  loader_start+KERNEL_LOAD_ADDR 装到 0x80010000, ELF 按其 vaddr
#                  装载; 且只有 Linux 镜像(is_linux)才会把 dtb 放进 r2、把 initrd
#                  写入 /chosen。故 -r 走 zImage 直启; U-Boot 产物照常由
#                  -b uboot 编出, 供 SDK/SD 引导与教学研究, 不参与 -r 引导。
#
# 目录约定(均相对本脚本所在目录 qemu-device/):
#   ../busybox ../kernel ../u-boot ../qemu-src   源码树(仓库根下, qemu-src 为软链)
#   板卡配置(各源码仓库自己管理, 统一用 mcimx6ul 标识, 本脚本只调用):
#     kernel/arch/arm/configs/mcimx6ul_defconfig
#     u-boot/configs/mcimx6ul_defconfig
#     busybox/configs/mcimx6ul_defconfig
#   build-mcimx6ul/{busybox,kernel,uboot,qemu-build}   O= 构建目录
#   build-mcimx6ul/rootfs                 busybox 安装出的 rootfs 骨架
#   build-mcimx6ul/rootfs-shell.cpio.gz   -r      交互 shell 版 initramfs
#   build-mcimx6ul/rootfs-test.cpio.gz    -r test 自动验证版 initramfs
#   build-mcimx6ul/imx6ul-14x14-evk.dtb   内核树拷出的设备树
#   build-mcimx6ul/qemu-install/bin/...   自编 QEMU(存在则 -r 优先使用)
#   out-mcimx6ul/boot.log                 最近一次串口日志
#
# 注: build-mcimx6ul/rootfs/init 与 etc/inittab 每次 -b rootfs 都重新写入,
#     如需定制请改下方 gen_init_test / gen_init_shell。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$ROOT/.." && pwd)"

SRC_BUSYBOX="$SRC/busybox"
SRC_KERNEL="$SRC/kernel"
SRC_UBOOT="$SRC/u-boot"
SRC_QEMU="$SRC/qemu-src"

BUILD="$ROOT/build-mcimx6ul"
OUT="$ROOT/out-mcimx6ul"

# --- 板卡参数 ---
MACHINE="mcimx6ul-evk"
MACHINE_DESC="Freescale i.MX6UL Evaluation Kit (Cortex-A7)"
CROSS_ARM="arm-linux-gnueabihf-"
# 三份配置由各自源码仓库自己维护, 统一用 mcimx6ul 标识:
#   kernel/arch/arm/configs/mcimx6ul_defconfig   -> make mcimx6ul_defconfig
#   u-boot/configs/mcimx6ul_defconfig            -> make mcimx6ul_defconfig
#   busybox/configs/mcimx6ul_defconfig           -> make mcimx6ul_defconfig
KERNEL_DEFCONFIG="$SRC_KERNEL/arch/arm/configs/mcimx6ul_defconfig"
UBOOT_DEFCONFIG="$SRC_UBOOT/configs/mcimx6ul_defconfig"
BUSYBOX_DEFCONFIG="$SRC_BUSYBOX/configs/mcimx6ul_defconfig"
KERNEL_DTB="imx6ul-14x14-evk"
CONSOLE="ttymxc0"
J="$(nproc)"

INITRAMFS="$BUILD/rootfs-test.cpio.gz"      # 自动验证版(-r test): VERIFY 标记 + poweroff
INITRAMFS_SHELL="$BUILD/rootfs-shell.cpio.gz"  # 交互终端版(-r): busybox init + 常驻 shell
ZIMAGE="$BUILD/kernel/arch/arm/boot/zImage"
DTB_SRC="$BUILD/kernel/arch/arm/boot/dts/nxp/imx/$KERNEL_DTB.dtb"
DTB="$BUILD/$KERNEL_DTB.dtb"
QEMU_BIN="$BUILD/qemu-install/bin/qemu-system-arm"

step()  { echo -e "\e[96m➤  $*\e[0m"; }
ok()    { echo "  ✅ $*"; }
warn()  { echo -e "  ⚠️  $*"; }
error() { echo -e "  ❌ $*" >&2; }
die()   { error "$*"; exit 1; }

usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; }

need_cross() {
    command -v "${CROSS_ARM}gcc" >/dev/null 2>&1 \
        || die "缺少 ${CROSS_ARM}gcc(32 位 ARM 交叉工具链): apt install gcc-arm-linux-gnueabihf"
}

# ---------------------------------------------------------------------------
# rootfs: busybox 静态编译 -> 安装 -> 写入 init/inittab -> 打包两份 initramfs
# ---------------------------------------------------------------------------
build_busybox() {
    step "busybox: mcimx6ul_defconfig (静态 armhf, 不装动态库, initramfs 才自洽)"
    local bb="$BUILD/busybox"
    mkdir -p "$bb"
    # 配置由 busybox 仓库自己维护: busybox/configs/mcimx6ul_defconfig
    # .config 缺失或源配置更新过时重新生成, 否则保持增量构建
    if [ ! -f "$bb/.config" ] || [ "$BUSYBOX_DEFCONFIG" -nt "$bb/.config" ]; then
        [ -f "$BUSYBOX_DEFCONFIG" ] || die "缺少 busybox 配置: $BUSYBOX_DEFCONFIG"
        make -C "$SRC_BUSYBOX" O="$bb" ARCH=arm CROSS_COMPILE="$CROSS_ARM" \
            mcimx6ul_defconfig >/dev/null
    fi
    make -C "$SRC_BUSYBOX" O="$bb" ARCH=arm CROSS_COMPILE="$CROSS_ARM" -j"$J"
    file -b "$bb/busybox" | grep -q 'ARM' \
        || die "busybox 不是 ARM 架构: $(file -b "$bb/busybox")(检查 CROSS_COMPILE)"
    ok "busybox: $(file -b "$bb/busybox" | cut -d, -f1-3)"
}

install_rootfs() {
    local r="$BUILD/rootfs"
    rm -rf "$r"
    # 注意必须带 ARCH/CROSS_COMPILE: install 依赖 _all, 缺参数会让 busybox
    # 用 host gcc 重编一遍, 把 arm 版二进制覆盖成 x86-64
    make -C "$SRC_BUSYBOX" O="$BUILD/busybox" ARCH=arm CROSS_COMPILE="$CROSS_ARM" \
        CONFIG_PREFIX="$r" install >/dev/null
    file -b "$r/bin/busybox" | grep -q 'ARM' \
        || die "rootfs 里的 busybox 架构不对: $(file -b "$r/bin/busybox")"
    mkdir -p "$r"/{dev,proc,sys,tmp,etc,root,mnt,run}
    chmod 1777 "$r/tmp"
    ok "rootfs 骨架: $r ($(du -sh "$r" | cut -f1))"
}

# 自动验证版 init: 挂载伪文件系统 -> 打印 VERIFY 标记 -> 关机(回归用)
gen_init_test() {
    cat > "$BUILD/rootfs/init" <<'EOF'
#!/bin/sh
# mcimx6ul-evk 验证用 init: 挂载伪文件系统 -> 打印验证标记 -> 关机
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo "VERIFY-BOARD:   $(cat /proc/device-tree/model 2>/dev/null)"
echo "VERIFY-KERNEL:  $(uname -a)"
echo "VERIFY-CPU:     $(uname -m), $(nproc) cores, $(grep MemTotal /proc/meminfo)"
echo "VERIFY-BUSYBOX: $(busybox | head -1)"
echo "VERIFY-LS:      $(ls / | tr '\n' ' ')"
echo "ALL-ARTIFACTS-VERIFIED: mcimx6ul-evk -> kernel $(uname -r) -> busybox alive"
sync
poweroff -f
EOF
    chmod 755 "$BUILD/rootfs/init"
    rm -f "$BUILD/rootfs/etc/inittab" "$BUILD/rootfs/etc/rc.sh"
}

# 交互终端版 init: 挂载伪文件系统后交给 busybox init(/etc/inittab) 接管,
# 由 respawn 条目在 ttymxc0 上常驻 shell —— exit 退出后自动重生
gen_init_shell() {
    cat > "$BUILD/rootfs/init" <<'EOF'
#!/bin/sh
# mcimx6ul-evk 交互模式 init: 挂载伪文件系统 -> 交给 busybox init(/etc/inittab)
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts && mount -t devpts devpts /dev/pts 2>/dev/null

echo "VERIFY-BOARD:   $(cat /proc/device-tree/model 2>/dev/null)"
echo "BOARD-READY: mcimx6ul-evk 交互串口终端, exit 退出后 shell 自动重生, poweroff 关机"
exec /sbin/init
EOF
    chmod 755 "$BUILD/rootfs/init"
    cat > "$BUILD/rootfs/etc/inittab" <<'EOF'
# busybox init: sysinit 做基础设置, ttymxc0 上常驻 shell(respawn, 退出即重生)
::sysinit:/etc/rc.sh
ttymxc0::respawn:/bin/sh
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF
    cat > "$BUILD/rootfs/etc/rc.sh" <<'EOF'
#!/bin/sh
hostname mcimx6ul-evk
ifconfig lo up 2>/dev/null
# QEMU mcimx6ul-evk 的 FEC 网卡走模型内置 PHY, 需要时可在这里 dhcp/静态配置
EOF
    chmod 755 "$BUILD/rootfs/etc/rc.sh"
}

# 打包 initramfs。内核 initramfs 不会自动创建 /dev/console(只 open),
# 本容器无 CAP_MKNOD, 故用内核自带 gen_init_cpio 生成设备节点归档再拼接。
pack_initramfs() {    # $1 = 输出文件
    local out="$1"
    step "打包 $(basename "$out")"
    if [ ! -x "$BUILD/gen_init_cpio" ]; then
        gcc -O2 -o "$BUILD/gen_init_cpio" "$SRC_KERNEL/usr/gen_init_cpio.c" \
            || die "编译 gen_init_cpio 失败(需要 host gcc)"
    fi
    printf 'dir /dev 0755 0 0\nnod /dev/console 0600 0 0 c 5 1\nnod /dev/null 0666 0 0 c 1 3\n' \
        > "$BUILD/dev.list"
    "$BUILD/gen_init_cpio" "$BUILD/dev.list" > "$BUILD/dev.cpio"
    ( cd "$BUILD/rootfs" \
        && find . -print0 | cpio --null -o -H newc --owner=0:0 2>/dev/null \
        | gzip -9 > "$BUILD/fs.cpio.gz" )
    { zcat "$BUILD/fs.cpio.gz"; cat "$BUILD/dev.cpio"; } | gzip -9 > "$out"
    rm -f "$BUILD/fs.cpio.gz"
    ok "$(basename "$out"): $(stat -c%s "$out") 字节"
}

build_rootfs() {
    need_cross
    [ -f "$SRC_BUSYBOX/Makefile" ] || die "缺少 $SRC_BUSYBOX 源码树"
    mkdir -p "$BUILD"
    build_busybox
    install_rootfs
    gen_init_test
    pack_initramfs "$INITRAMFS"
    gen_init_shell
    pack_initramfs "$INITRAMFS_SHELL"
}

# ---------------------------------------------------------------------------
# kernel: i.MX6UL 32 位内核 + EVK 设备树
# ---------------------------------------------------------------------------
build_kernel() {
    need_cross
    [ -f "$KERNEL_DEFCONFIG" ] || die "缺少内核配置: $KERNEL_DEFCONFIG"
    mkdir -p "$BUILD/kernel"
    step "kernel: mcimx6ul_defconfig (ARCH=arm, ARCH_MXC/SOC_IMX6UL)"
    if [ ! -f "$BUILD/kernel/.config" ] || [ "$KERNEL_DEFCONFIG" -nt "$BUILD/kernel/.config" ]; then
        make -C "$SRC_KERNEL" O="$BUILD/kernel" ARCH=arm CROSS_COMPILE="$CROSS_ARM" \
            mcimx6ul_defconfig >/dev/null
    fi
    make -C "$SRC_KERNEL" O="$BUILD/kernel" ARCH=arm CROSS_COMPILE="$CROSS_ARM" \
        -j"$J" zImage dtbs
    [ -f "$ZIMAGE" ] || die "zImage 缺失: $ZIMAGE"
    [ -f "$DTB_SRC" ] || die "dtb 缺失: $DTB_SRC"
    cp -f "$DTB_SRC" "$DTB"
    ok "zImage: $(stat -c%s "$ZIMAGE") 字节"
    ok "dtb:    $DTB ($KERNEL_DTB, 含 uart1/usdhc1/fec)"
}

# ---------------------------------------------------------------------------
# uboot: mx6ul_14x14_evk 引导产物(不参与 -r 引导, 见文件头说明)
# ---------------------------------------------------------------------------
build_uboot() {
    need_cross
    [ -f "$UBOOT_DEFCONFIG" ] || die "缺少 u-boot 配置: $UBOOT_DEFCONFIG"
    mkdir -p "$BUILD/uboot"
    step "u-boot: mcimx6ul_defconfig (TEXT_BASE=0x87800000)"
    if [ ! -f "$BUILD/uboot/.config" ] || [ "$UBOOT_DEFCONFIG" -nt "$BUILD/uboot/.config" ]; then
        make -C "$SRC_UBOOT" O="$BUILD/uboot" ARCH=arm CROSS_COMPILE="$CROSS_ARM" \
            mcimx6ul_defconfig >/dev/null
    fi
    make -C "$SRC_UBOOT" O="$BUILD/uboot" ARCH=arm CROSS_COMPILE="$CROSS_ARM" -j"$J"
    local u="$BUILD/uboot"
    [ -s "$u/u-boot-dtb.bin" ] || die "u-boot-dtb.bin 缺失"
    ok "u-boot-dtb.bin: $(stat -c%s "$u/u-boot-dtb.bin") 字节"
    [ -s "$u/u-boot-with-spl.imx" ] \
        && ok "u-boot-with-spl.imx: $(stat -c%s "$u/u-boot-with-spl.imx") 字节(真板 SD 引导用)"
    warn "本板 QEMU 无 BootROM/pflash, u-boot 不能作为 -bios 使用; -r 走 zImage 直启"
}

# ---------------------------------------------------------------------------
# qemu: 仓库内 11.1.3 源码编译(arm-softmmu), 供后续板卡开发使用
# ---------------------------------------------------------------------------
build_qemu() {
    [ -x "$SRC_QEMU/configure" ] || die "缺少 $SRC_QEMU/configure(qemu-src 软链是否有效?)"
    mkdir -p "$BUILD/qemu-build"
    step "qemu: 11.1.3 / arm-softmmu -> $BUILD/qemu-install"
    if [ ! -f "$BUILD/qemu-build/build.ninja" ]; then
        ( cd "$BUILD/qemu-build" \
            && "$SRC_QEMU/configure" \
                --target-list=arm-softmmu \
                --prefix="$BUILD/qemu-install" \
                --disable-docs --disable-werror --disable-guest-agent ) \
            || die "qemu configure 失败(依赖: glib-2.0/pixman-1/zlib dev, ninja; dtc/slirp 子项目需联网)"
    fi
    make -C "$BUILD/qemu-build" -j"$J"
    make -C "$BUILD/qemu-build" install
    [ -x "$QEMU_BIN" ] || die "qemu-system-arm 未生成: $QEMU_BIN"
    ok "$("$QEMU_BIN" --version | head -1)"
}

# ---------------------------------------------------------------------------
# 启动
# ---------------------------------------------------------------------------
pick_qemu() {
    if [ -x "$QEMU_BIN" ]; then
        echo "$QEMU_BIN"
    elif command -v qemu-system-arm >/dev/null 2>&1; then
        warn "未找到自编 QEMU, 回退系统 $(qemu-system-arm --version | head -1)" >&2
        command -v qemu-system-arm
    else
        die "找不到 qemu-system-arm, 请先执行 ./build_mcimx6ul.sh -b qemu"
    fi
}

do_run() {
    local verify=0 a
    local extra=()
    for a in "$@"; do
        case "$a" in
            test) verify=1 ;;
            *) extra+=("$a") ;;
        esac
    done

    local cpio="$INITRAMFS_SHELL" cmdline
    if [ "$verify" -eq 1 ]; then
        cpio="$INITRAMFS"
        cmdline="console=$CONSOLE,115200 rdinit=/init loglevel=7 panic=1"
    else
        cmdline="console=$CONSOLE,115200 rdinit=/init loglevel=7"
    fi

    step "检查成果物"
    local qemu fail=0
    qemu="$(pick_qemu)" || exit 1
    ok "qemu: $qemu"
    if [ -f "$ZIMAGE" ] && file -b "$ZIMAGE" | grep -qi 'ARM'; then
        ok "zImage: $(stat -c%s "$ZIMAGE") 字节"
    else
        error "缺少 zImage, 请先 -b kernel"; fail=1
    fi
    if [ -f "$DTB" ]; then
        ok "dtb: $(stat -c%s "$DTB") 字节 ($KERNEL_DTB)"
    else
        error "缺少 dtb, 请先 -b kernel"; fail=1
    fi
    if [ -f "$cpio" ] && zcat "$cpio" 2>/dev/null | cpio -it --quiet 2>/dev/null | grep -q '^init$'; then
        ok "$(basename "$cpio"): $(stat -c%s "$cpio") 字节, 含 /init"
    else
        error "$(basename "$cpio") 缺失或缺少 /init, 请先 -b rootfs"; fail=1
    fi
    [ "$fail" -eq 0 ] || die "成果物检查未通过"

    mkdir -p "$OUT"
    if [ "$verify" -eq 1 ]; then
        step "启动 $MACHINE [验证模式] (打 VERIFY 标记后自动关机; 日志: $OUT/boot.log)"
        extra=(-no-reboot "${extra[@]}")
    else
        step "启动 $MACHINE [交互终端] (exit 重生 shell; poweroff 关机; Ctrl-A x 强退)"
    fi

    set +e
    "$qemu" -M "$MACHINE" -m 512M -nographic \
        -kernel "$ZIMAGE" \
        -dtb "$DTB" \
        -initrd "$cpio" \
        -append "$cmdline" \
        "${extra[@]}" 2>&1 | tee "$OUT/boot.log"
    local rc=${PIPESTATUS[0]}
    set -e

    if [ "$verify" -eq 1 ]; then
        if grep -q 'ALL-ARTIFACTS-VERIFIED' "$OUT/boot.log"; then
            ok "启动验证通过(VERIFY 标记齐全), QEMU exit=$rc"
        else
            warn "未检测到完整验证标记, QEMU exit=$rc, 完整日志见 $OUT/boot.log"
            [ "$rc" -eq 0 ] || exit "$rc"
        fi
    else
        ok "串口终端已退出 (exit=$rc); 再次进入: ./build_mcimx6ul.sh -r"
    fi
}

do_clean() {
    step "删除构建产物"
    local d
    for d in "$BUILD" "$OUT"; do
        if [ -d "$d" ]; then
            echo "  rm -rf $d ($(du -sh "$d" 2>/dev/null | cut -f1))"
            rm -rf "$d"
        else
            echo "  (无 $d)"
        fi
    done
    ok "已清理, 重新构建请执行 ./build_mcimx6ul.sh -b all"
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
build_one() {
    case "$1" in
        rootfs) build_rootfs ;;
        kernel) build_kernel ;;
        uboot)  build_uboot ;;
        qemu)   build_qemu ;;
        *) die "未知组件 '$1' (可选: rootfs kernel uboot qemu all)" ;;
    esac
}

do_build() {
    local comps=() c
    for c in "$@"; do
        case "$c" in
            all) comps+=(rootfs kernel uboot qemu) ;;
            *) comps+=("$c") ;;
        esac
    done
    [ "${#comps[@]}" -gt 0 ] || die "-b 需要指定组件: rootfs kernel uboot qemu all"
    for c in "${comps[@]}"; do
        step "===== 构建组件: $c ====="
        build_one "$c"
    done
    step "完成: ./build_mcimx6ul.sh -r 交互启动 | ./build_mcimx6ul.sh -r test 验证启动"
}

main() {
    [ $# -gt 0 ] || { usage; exit 0; }
    local arg comps=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -b)
                shift
                [ $# -gt 0 ] || die "-b 后面要跟组件名"
                IFS=',' read -r -a _c <<< "$1"
                comps+=("${_c[@]}")
                ;;
            -b*,*|-b*)
                IFS=',' read -r -a _c <<< "${1#-b}"
                comps+=("${_c[@]}")
                ;;
            -r) shift; do_run "$@"; exit 0 ;;
            -c) do_clean; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知参数 '$1' (用 -h 看用法)" ;;
        esac
        shift
    done
    do_build "${comps[@]}"
}

main "$@"
