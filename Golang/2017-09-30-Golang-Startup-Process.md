---
layout: post
title: Golang 的启动过程分析
date: 2017-09-30 09:49:32 +0800
description: Golang 的启动过程分析
tags: [Golang]
---
 
#### 系统环境

系统版本： Fedora Release 25  
内核版本：4.12.8-200.fc25.x86\_64  
GO: 1.10.1 linux/amd64  

#### 从二进制中查找 Entry Point
首先编译一个 go 的二进制程序（此处我编译的是 golang/dep 项目），然后使用 objdump 或者 readelf 取得程序的入口地址：
```
$ objdump -f dep

dep:     file format elf64-x86-64
architecture: i386:x86-64, flags 0x00000112:
EXEC_P, HAS_SYMS, D_PAGED
start address 0x00000000004581d0

```
可以看到启动地址为 0x0000000000454420（地址不一定和此处相同）。  
然后对程序进行反汇编：
```
$ objdump -d dep > dep.asm
```
然后使用任意文本工具查看 dep.asm，并找到 4581d0 地址出的汇编：
```asm
  454420:       48 8b 3c 24             mov    (%rsp),%rdi
  454424:       48 8d 74 24 08          lea    0x8(%rsp),%rsi
  454429:       e9 02 00 00 00          jmpq   454430 <_cgo_topofstack@@Base-0x2e50>
   ...
  454430:       48 89 f8                mov    %rdi,%rax
  454433:       48 89 f3                mov    %rsi,%rbx
  454436:       48 83 ec 27             sub    $0x27,%rsp
  45443a:       48 83 e4 f0             and    $0xfffffffffffffff0,%rsp
  45443e:       48 89 44 24 10          mov    %rax,0x10(%rsp)
  454443:       48 89 5c 24 18          mov    %rbx,0x18(%rsp)
  454448:       48 8d 3d 91 41 85 00    lea    0x854191(%rip),%rdi        # ca85e0 <sigismember@plt+0x425410>
  45444f:       48 8d 9c 24 68 00 ff    lea    -0xff98(%rsp),%rbx
  ...
  4581d0:       e9 4b c2 ff ff          jmpq   454420 <_cgo_topofstack@@Base-0x2e60>
```
入口点 4581d0 对应的函数位于：runtime/rt0\_linux\_amd64.s#7
```asm
TEXT _rt0_amd64_linux(SB),NOSPLIT,$-8
	JMP	_rt0_amd64(SB)
```
这个函数直接跳转到了 \_rt0\_amd64：runtime/asm\_amd64.s#14
```
TEXT _rt0_amd64(SB),NOSPLIT,$-8
	MOVQ	0(SP), DI	// argc
	LEAQ	8(SP), SI	// argv
	JMP	runtime·rt0_go(SB)
```
\_rt0\_amd64 只是把 argc 和 argv 放入到 rdi 和 rsi 寄存器，然后调用 rt0\_go 函数：runtime/asm\_amd64.s#87
```
TEXT runtime·rt0_go(SB),NOSPLIT,$0
	// 此处将 rsp -= 39，然后按照 16 字节对齐，此时栈上至少有 39 字节可用。
	// 然后将 argc 和 argv 复制到 rsp+16 和 rsp+24 的位置。
	MOVQ	DI, AX		// argc
	MOVQ	SI, BX		// argv
	SUBQ	$(4*8+7), SP		// 2args 2auto
	ANDQ	$~15, SP
	MOVQ	AX, 16(SP)
	MOVQ	BX, 24(SP)
```
此时栈布局如下
```
+----------------------+
|     Stack Layout     |
+----------------------+
| ...                  |
| argc                 |
| argv                 |
| envp                 |
| ...                  |
| argv pointers        |
| NULL                 |
| environment pointers |
| NULL                 |
| ELF Auxiliary Table  |
| argv strings         |
| environment strings  |
| program name         |
| NULL                 |
+----------------------+ <--- 以上部分是 linux 启动进程时填充的
| ...                  |
| argv (rsp+24)        |
| argc (rsp+16)        |
| (Not Set) (rsp+8)    |
| (Not Set) (rsp+0)    |
+----------------------+ <--- rsp
```
初始化 g0，g0 的栈实际上就是 linux 分配的栈。g0 占用了大约 64k 的大小。
```
	// runtime.g0 位于 runtime/proc.go#80 
	// g0.stackguard0 =  rsp-64*1024+104
	// g0.stackguard1 = g0.stackguard0
	// g0.stack.lo = g0.stackguard0
	// g0.stack.hi = rsp
	MOVQ	$runtime·g0(SB), DI
	LEAQ	(-64*1024+104)(SP), BX
	MOVQ	BX, g_stackguard0(DI)
	MOVQ	BX, g_stackguard1(DI)
	MOVQ	BX, (g_stack+stack_lo)(DI)
	MOVQ	SP, (g_stack+stack_hi)(DI)
```
此处之后是一段探测 CPU 和 指令集的代码，忽略。

如果启用了 cgo，则会对 cgo 进行初始化：
```
	// 检查是否存在 _cgo_init 函数，如果有就执行
	MOVQ	_cgo_init(SB), AX
	TESTQ	AX, AX
	JZ	needtls
	// 这里的 DI 就是上面初始化 g0 时设置的 g0 的地址
	MOVQ	DI, CX	// Win64 uses CX for first parameter
	MOVQ	$setg_gcc<>(SB), SI
	CALL	AX

	// _cgo_init 初始化完成之后，重新设置 g0 的 stack 守卫。
	MOVQ	$runtime·g0(SB), CX
	MOVQ	(g_stack+stack_lo)(CX), AX
	// _StackGuard 位于 runtime/stack.go#93
	ADDQ	$const__StackGuard, AX
	MOVQ	AX, g_stackguard0(CX)
	MOVQ	AX, g_stackguard1(CX)
```
如果没有启用 cgo，则会初始化 Thread local storage：
```
needtls:
	// runtime.m0 位于 runtime/proc.go#79
	LEAQ	runtime·m0+m_tls(SB), DI
	// settls 位于 runtime/sys_linux_amd64.s#601
	CALL	runtime·settls(SB)

	// get_tls 和 g 是宏，位于 runtime/go_tls.h#10
	// #define	get_tls(r)	MOVQ TLS, r
	// #define	g(r)	0(r)(TLS*1)
	// 此处对 tls 进行了一次测试，确保值正确写入了 m0.tls
	get_tls(BX)
	MOVQ	$0x123, g(BX)
	MOVQ	runtime·m0+m_tls(SB), AX
	CMPQ	AX, $0x123
	JEQ 2(PC)
	MOVL	AX, 0	// abort
```
完成汇编部分的初始化工作：
```
ok:
	// 将 g0 放到 tls 里，这里实际上就是 m0.tls
	get_tls(BX)
	LEAQ	runtime·g0(SB), CX
	MOVQ	CX, g(BX)
	LEAQ	runtime·m0(SB), AX

	// m->g0 = g0
	MOVQ	CX, m_g0(AX)
	// g0->m = m0
	MOVQ	AX, g_m(CX)

	CLD
	// check 位于 runtime/runtime1.go#136
	// 这个函数检查了各种类型以及类型转换是否有问题
	CALL	runtime·check(SB)

	// 将 argc 和 argv 移动到 rsp+0 和 rsp+8 的位置，模拟函数调用时对参数的 push
	// 此处完成了 args 的分析，os 初始化，调度器初始化。
	MOVL	16(SP), AX		// copy argc
	MOVL	AX, 0(SP)
	MOVQ	24(SP), AX		// copy argv
	MOVQ	AX, 8(SP)
	// args 位于 runtime/runtime1.go#60
	// args 会去 stack 里读取参数和环境变量以及 Auxiliary Table
	CALL	runtime·args(SB)
	// osinit 位于 runtime/os_linux.go#272
	// osinit 初始化 cpu 数量
	CALL	runtime·osinit(SB)
	// schedinit 位于 runtime/proc.go#477
	// schedinit 初始化调度器，内存，参数，环境变量，gc
	// schedinit 初始化根据 cpu 数量和 GOMAXPROCS 确定需要的 p 的数量，
	// 然后将 m0 的 p 设置为创建的第一个 p
	CALL	runtime·schedinit(SB)

	// 获取 runtime.main 的地址，调用 newproc 创建 p
	MOVQ	$runtime·mainPC(SB), AX
	PUSHQ	AX
	PUSHQ	$0			// arg size
	// newproc 位于 runtime/proc.go#3240
	// newproc 创建一个新的 g 并放置到等待队列里
	CALL	runtime·newproc(SB)
	POPQ	AX
	POPQ	AX

	// mstart 位于 runtime/proc.go#1175
	// mstart 会调用 schedule 函数进入调度状态
	CALL	runtime·mstart(SB)

	MOVL	$0xf1, 0xf1  // crash
	RET

DATA	runtime·mainPC+0(SB)/8,$runtime·main(SB)
GLOBL	runtime·mainPC(SB),RODATA,$8
```
