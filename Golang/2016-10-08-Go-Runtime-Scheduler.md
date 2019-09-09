---
layout: post
title: Go runtime 调度器
date: 2016-10-08 09:45:13 +0800
description: Go runtime 调度器源码分析
tags: [Golang]
---
 
#### 分析环境:  
go:1.7 linux amd64  
分析中使用的汇编相关的内容也是 64 位的, 例如栈顶寄存器 rsp 等 (32 位的是 esp,16 位的是 sp)  

#### 1.Go 调度器结构

##### G:runtime.g(runtime/runtime2.go#306)，该结构体用于描述一个 goroutine
```go
// 栈
type stack struct {
    // 栈下界指针
    lo uintptr
    // 栈上界指针
    hi uintptr
}
// 代表一个 goroutine
type g struct {
    // 描述当前 g 的栈信息
    stack       stack
    // 栈界限 (守卫), 用于一般 goroutine
    stackguard0 uintptr
    // 栈界限 (守卫), 用于 g0 和 gsignal
    stackguard1 uintptr
    // 如果 G 正在运行, m 指向运行当前 goroutine 的 M
    m           *m
    //goroutine 现场信息, 在 goroutine 切换的时候需要保存和恢复该信息
    sched       gobuf
    // 当前 G 的状态 (参考 runtime/runtime2.go#14)
    atomicstatus   uint32
    // 标记是否要抢占式调度
    preempt        bool
    // 锁定 M, 即表示当前的 G 具有线程亲和性, 需要在制定的线程中执行
    lockedm     *m
    // 其他字段
    ...
}
```
栈的范围是 [lo, hi)，栈是从上往下使用的, 即开始时 rsp 为 hi，当 push 一个 64 位指针后, rsp=hi-8, 此时栈已使用部分为 [rsp,hi)。  

每个 goroutine 创建时都会创建一个对应的 g 结构体，g 结构体中包含了该 goroutine 的所有信息。  

go 在编译函数的时候, 会在每个函数的开头插入一段代码，代码判断 rsp < staic.lo+StackGuard，如果为 true 则表示剩余的栈空间不够用了, 需要对栈进行扩容。
扩容后栈变为当前栈的 2 倍，并且将当前栈的所有数据复制到新的栈中，并改变 g 的 stack 相关信息。  


##### M:runtime.m(runtime/runtime2.go#377)，该结构体用于描述一个操作系统线程
```go
type m struct {
    // 拥有调度栈的 goroutine
    g0      *g
    // 处理信号的 goroutine
    gsignal *g
    // 附加在当前 M 上的 P, 如果当前 M 处于空闲状态, p 为 nil
    p        puintptr
    // 操作系统线程 handle
    thread   uintptr
    // 为 true 说明当前线程正处于没事找事的状态
    spinning bool
    // 其他字段
    ...
}
```
M 与操作系统线程一一对应，M 与 P 关联，并且在 P 给出 G 后，执行 G。

##### P:runtime.p(runtime/runtime2.go#444)，该结构体描述一个 go processor 结构
```go
type p struct {
    // 处理器状态 (参考 runtime/runtime2.go#91)
    status      uint32
    // 关联的线程 M 信息, 如果 P 处于空闲状态, m 为 nil
    m           muintptr
    // 当前 P 所持有的 G 队列, P 处于运行状态时从该队列中 pop 出一个 G 来执行
    runqhead uint32
    runqtail uint32
    runq     [256]guintptr
    // 处于死亡状态的 G, 作为对象池来使用
    // 当前 P 上的 G 新建 goroutine 的时候会先从这里取出已经死亡的 G 来使用, 避免频繁创建 G 结构体
    gfree    *g
    gfreecnt int32
    // 其他字段
    ...
}
```

P 负责管理 G 的运行队列，通常情况下，P 的数量和 CPU 核心的数量一致（可以通过 GOMAXPROCS 修改 P 的数量）。  
P 的基本流程：
1. 一个运行状态的 P（已经绑定了一个 M）首先从全局运行队列里获取 G 来运行
2. 如果全局运行队列内没有可以运行的 G，那么去其他 P 那里获取一半的运行队列（分摊工作），并开始运行
3. 如果 1 和 2 都没有找到可以运行的 G，那么进入空闲状态，同时对应的 M 也进入空闲的状态
4. 如果当前运行的 G 进入 SYSCALL 状态，那么 G 所属的 P 会 * 单方面解除 * 对 M 的引用（entersyscall 时执行），此时 P 处于 Psyscall 状态
5. 解除绑定后的 P 接受 sysmon 管理，并且由 sysmon 重新分配一个可以运行的 M，此后 P 会继续执行其他的 G（runtime/proc.go#3687 retake）
6. 如果在此期间 sysmon 找不到空闲的 M，那么 sysmon 会将 P 设置为空闲状态，并将 P 剩余的 G 放到全局运行队列中（runtime/proc.go#1663 handoffp）
7. 由于 sysmon 是周期性执行，因此如果在 sysmon 处理 P 之前 SYSCALL 就已经返回了，那么 M 能够通过对 P 的引用找回 P 并重新开始执行 (exitsyscall 时执行)

#### 2.sysmon 系统监控
sysmon 是监控线程，用于监控系统的运行状况，包括 G，P，M 的执行情况，网络的状态检查等。（runtime/proc.go#3580 sysmon）
```go
// sysmon 运行过程中不需要 P，总是独占一个线程
func sysmon() {
    // 记录下面的 for 循环连续没事做的次数
	idle := 0
    // 延迟时间, 即下次运行前 sleep 的时间
	delay := uint32(0)
	for {
		if idle == 0 {
            // 如果上次循环的时候就有事做，那么下次做事前先休息 20 微秒
			delay = 20
		} else if idle > 50 {
            // 如果前面 50 次循环都没有事情做，那么睡眠时间开始增长
			delay *= 2
		}
		if delay > 10*1000 {
            // 睡眠时间不能超过 10ms
			delay = 10 * 1000
		}
        // 调用操作系统的 sleep 函数让 M(操作系统线程) 休眠, 与 time.Sleep 不同, time.Sleep 只会让 G 休眠而不会让 M 休眠
		usleep(delay)
        // 忽略部分代码
        ...
        // 检查网络状态, 即对于那些因网络调用而阻塞的 G, 在此处检查相应状态, 如果状态符合要求就将对应的 G 从 Gwaiting 转换为 Grunnable
		// poll network if not polled for more than 10ms
		lastpoll := int64(atomic.Load64(&sched.lastpoll))
		now := nanotime()
		unixnow := unixnanotime()
		if lastpoll != 0 && lastpoll+10*1000*1000 < now {
			atomic.Cas64(&sched.lastpoll, uint64(lastpoll), uint64(now))
			gp := netpoll(false) // non-blocking - returns list of goroutines
			if gp != nil {
				// Need to decrement number of idle locked M's
				// (pretending that one more is running) before injectglist.
				// Otherwise it can lead to the following situation:
				// injectglist grabs all P's but before it starts M's to run the P's,
				// another M returns from syscall, finishes running its G,
				// observes that there is no work to do and no other running M's
				// and reports deadlock.
				incidlelocked(-1)
				injectglist(gp)
				incidlelocked(1)
			}
		}
        // 在此处检查处于 SYSCALL 的 P 并进行处理
		//retake 还检查了执行过长的 G
		if retake(now) != 0 {
			idle = 0
		} else {
			idle++
		}
		// 检查是否需要 GC
		lastgc := int64(atomic.Load64(&memstats.last_gc))
		if gcphase == _GCoff && lastgc != 0 && unixnow-lastgc > forcegcperiod && atomic.Load(&forcegc.idle) != 0 {
			lock(&forcegc.lock)
			forcegc.idle = 0
			forcegc.g.schedlink = 0
			injectglist(forcegc.g)
			unlock(&forcegc.lock)
		}
		// scavenge heap once in a while
		if lastscavenge+scavengelimit/2 < now {
			mheap_.scavenge(int32(nscavenge), uint64(now), uint64(scavengelimit))
			lastscavenge = now
			nscavenge++
		}
		if debug.schedtrace > 0 && lasttrace+int64(debug.schedtrace)*1000000 <= now {
			lasttrace = now
			schedtrace(debug.scheddetail > 0)
		}
	}
}
```
处于 SYSCALL 状态的 P 的执行依赖于 retake 方法（runtime/proc.go#3687 retake）：
```go
func retake(now int64) uint32 {
	n := 0
    // 遍历所有的 P
	for i := int32(0); i < gomaxprocs; i++ {
		_p_ := allp[i]
		if _p_ == nil {
			continue
		}
		pd := &pdesc[i]
		s := _p_.status
		if s == _Psyscall {
            // 超过一次 sysmon 循环所需要的时间的 P, 才会被 retake 处理, 具体时间由 sysmon 的 delay 决定, 最少 20 微秒
			// Retake P from syscall if it's there for more than 1 sysmon tick (at least 20us).
			t := int64(_p_.syscalltick)
			if int64(pd.syscalltick) != t {
				pd.syscalltick = uint32(t)
				pd.syscallwhen = now
				continue
			}
			// On the one hand we don't want to retake Ps if there is no other work to do,
			// but on the other hand we want to retake them eventually
			// because they can prevent the sysmon thread from deep sleep.
			if runqempty(_p_) && atomic.Load(&sched.nmspinning)+atomic.Load(&sched.npidle) > 0 && pd.syscallwhen+10*1000*1000 > now {
				continue
			}
			// Need to decrement number of idle locked M's
			// (pretending that one more is running) before the CAS.
			// Otherwise the M from which we retake can exit the syscall,
			// increment nmidle and report deadlock.
			incidlelocked(-1)
			if atomic.Cas(&_p_.status, s, _Pidle) {
				if trace.enabled {
					traceGoSysBlock(_p_)
					traceProcStop(_p_)
				}
				n++
				_p_.syscalltick++
				handoffp(_p_)
			}
			incidlelocked(1)
		} else if s == _Prunning {
            // 如果 P 处于运行状态, 并且 G 运行时间太久了, 那么就对 G 进行抢占
			// Preempt G if it's running for too long.
			t := int64(_p_.schedtick)
			if int64(pd.schedtick) != t {
				pd.schedtick = uint32(t)
				pd.schedwhen = now
				continue
			}
			if pd.schedwhen+forcePreemptNS > now {
				continue
			}
			preemptone(_p_)
		}
	}
	return uint32(n)
}
```
在 retake 中发生的抢占式调度的说明：  
1. 通过记录一个 G 的执行时间来判断 G 是否执行太久  
2. 通过设置 G 的 preempt（设置为 true）和 stackguard0（设置为 stackPreempt runtime/static.go#135）来标记该 G 需要被抢占式调度  
3. 这个抢占式调度是被动的，只有当 G 发生函数调用时，在函数头进行栈检查的时候，才会去检查是否要让出执行权。
  
如果发生以下两种情况，那么抢占式调度无效：  
1. G 执行过程中，不调用其他函数  
2. G 调用其他函数，但是这些函数头部没有栈检查（当 go 的编译器认为该函数所需栈太小时, 就不会给在该函数头部添加栈检查）  
