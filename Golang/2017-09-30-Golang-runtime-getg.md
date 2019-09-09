---
layout: post
title: Golang runtime.getg() 的实现
date: 2017-09-30 09:28:18 +0800
description: Golang runtime.getg() 的实现
tags: [Golang]
---
 
#### 系统环境

系统版本： Fedora Release 25  
内核版本：4.12.8-200.fc25.x86\_64  
GO: 1.8.3 linux/amd64  

#### runtime.getg()
这个函数用于获取当前正在执行的 goroutine 的信息（/usr/local/go/src/runtime/stubs.go#21）。
```go
// getg returns the pointer to the current g.
// The compiler rewrites calls to this function into instructions
// that fetch the g directly (from TLS or from the dedicated register).
func getg() *g
```
从注释里可以看到，这个函数并不是在 runtime 里实现的，而是由编译器负责写入函数体。而且写明了是来自于 TLS（Thread-local Storage）或者指定的寄存器的。

然后在编译器中搜索 getg 相关的内容，可以在 ssa.go 中发现与之相关的说明（cmd/compile/internal/amd64/ssa.go#712）：
```go
case ssa.OpAMD64LoweredGetG:
	r := v.Reg()
	// See the comments in cmd/internal/obj/x86/obj6.go
	// near CanUse1InsnTLS for a detailed explanation of these instructions.
	if x86.CanUse1InsnTLS(gc.Ctxt) {
		// MOVQ (TLS), r
		...
	} else {
		// MOVQ TLS, r
		// MOVQ (r)(TLS*1), r
		...
	}
```
这里判断了能否使用单命令访问 TLS，可以就用第一种实现，否则使用第二种实现。也就是说，getg() 最终是从当前线程的 TLS 中取得 g 的信息。
