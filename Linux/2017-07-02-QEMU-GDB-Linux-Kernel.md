---
layout: post
title: 使用 QEMU 和 GDB 调试 Linux 内核 v4.12
date: 2017-07-02 02:26:06 +0800
description: 使用 QEMU 和 GDB 调试 Linux 内核 v4.12
tags: [Linux]
---
 

#### 系统环境
系统版本： Fedora Release 25  
内核版本：4.8.6-300-fc25.x86\_64  
QEMU：2.7.1-6.fc25  
GDB：7.12-24.fc25  
GCC： 6.2.1  
MAKE： 4.1  

#### 编译内核
内核下载地址（目前最新版本为：v4.12-rc7）：
```
git clone https://github.com/torvalds/linux.git
cd ./linux
```
内核比较大，clone 时间可能会比较长。  
完成之后，执行如下命令设置内核：
```
# 创建 x86_64 的默认内核配置
make x86_64_defconfig
# 手动设置内核选项
make menuconfig
# 如果上一步的命令出现错误，并提示缺少 ncurses，那么使用如下命令安装
sudo dnf install ncurses-devel
```
在 menu 中，需要设置以下几个选项，否则会导致无法断点调试：
1. 取消 Processor type and features -> Build a relocatable kernel  
    取消后 Build a relocatable kernel 的子项 Randomize the address of the kernel image (KASLR)  也会一并被取消
2. 打开 Kernel hacking -> Compile-time checks and compiler options 下的选项：
    - Compile the kernel with debug info
       - Generate dwarf4 debuginfo
    - Compile the kernel with frame pointers

完成设置之后 Save 保存为 .config 后退出 menu。  
使用如下命令编译内核：
```
# 8 表示使用 8 个 cpu 核心进行编译，需要根据自己的 cpu 核心数量设置。
# 如果编译过程中出现错误，按照错误提示安装相应的开发包即可。
make -j 8
```
编译需要一定的时间，完成后内核镜像会放在 ./arch/x86/boot/bzImage。

#### 调试内核
使用 qemu 执行内核并等待调试：
```
# 选项说明
# -m 指定内存数量
# -kernel 指定 bzImage 的镜像路径
# -s 等价于 -gdb tcp::1234 表示监听 1234 端口，用于 gdb 连接
# -S 表示加载后立即暂停，等待调试指令。不设置这个选项内核会直接执行
# -nographic 以及后续的指令用于将输出重新向到当前的终端中，这样就能方便的用滚屏查看内核的输出日志了。
qemu-system-x86_64 -m2048 -kernel ./arch/x86/boot/bzImage -s -S -nographic -serial mon:stdio -append "console=ttyS0"
```
这个时候 qemu 会进入暂停状态，如果需要打开 qemu 控制台，可以输入 CTRL + A  然后按 C。  

在另一个终端中执行 gdb：
```
# vmlinux 是编译内核时生成的调试文件，在内核源码的根目录中。
gdb vmlinux
# 进入 gdb 的交互模式后，首先执行
show arch
# 当前架构一般是: i386:x86-64

# 连接 qemu 进行调试：
target remote :1234
# 设置断点
# 如果上面 qemu 是使用 qemu-kvm 执行的内核的话，就需要使用 hbreak 来设置断点，否则断点无法生效。
# 但是我们使用的是 qemu-system-x86_64，所以可以直接使用 b 命令设置断点。
b start_kernel
# 执行内核
c
```
执行内核后，gdb 会出现一个错误：
```
Remote 'g' packet reply is too long: 后续一堆的十六进制数字
```
这是 gdb 的一个 bug，可以通过以下方式规避：
```
# 断开 gdb 的连接
disconnect
# 重新设置 arch
# 此处设置和之前 show arch 的要不一样
# 之前是  i386:x86-64 于是改成  i386:x86-64:intel
set arch i386:x86-64:intel
```
设置完 arch 后，重新连接：
```
target remote :1234
```
连接上后就可以看到 gdb 正常的输出 start\_kernel 处的代码，然后按照 gdb 的调试指令进行内核调试即可。

#### 问题 & 解决方案
1. 为什么要关闭 Build a relocatable kernel   
    因为内核启用这项特性之后，内核启动时会随机化内核的各个 section 的虚拟地址（VA），导致 gdb 断点设置在错误的虚拟地址上，内核执行时就不会触发这些断点。  

2.  Generate dwarf4 debuginfo 有什么用  
    方便 gdb 调试。可参考 dwarf4 格式。

3. Remote 'g' packet reply is too long 错误的原因  
    这个错误是当目标程序执行时发生模式切换（real mode 16bit -> protected mode 32bit -> long mode 64bit）的时候，gdb server（此处就是 qemu）发送了不同长度的信息，gdb 无法正确的处理这种情况，所以直接就报错。  
    此时需要断开连接并切换 gdb 的 arch （i386:x86-64 和 i386:x86-64:intel ），arch 变化后，gdb 会重新设置缓冲区，然后再连接上去就能正常调试。这个方法规避了一些麻烦，但是实际上有两种正规的解决方案：  
    （1） 修改 gdb 的源码，使 gdb 支持这种长度变化（gdb 开发者似乎认为这个问题应该由 gdb server 解决）。  
    （2） 修改 qemu 的 gdb server，始终发送 64bit 的消息（但是这种方式可能导致无法调试 real mode 的代码）。  

4. 为什么最后内核执行出现了 Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)  
    因为 qemu 没有加载 rootfs，所以内核最后挂 VFS 的时候会出错。可以用 busybox 构建一个文件系统镜像，然后 qemu 增加 -initrd 选项指向该文件系统镜像即可。
