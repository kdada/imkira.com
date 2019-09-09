---
layout: post
title: Golang 中不使用分代和紧凑型 GC 的原因
date: 2017-05-18 02:52:19 +0800
description: Golang 中不使用分代和紧凑型 GC 的原因
tags: [Golang]
---
 
来源：[Why golang garbage-collector not implement Generational and Compact gc](https://groups.google.com/forum/m/#!topic/golang-nuts/KJiyv2mV2pU)

紧凑型 GC 拥有如下优点：  
1. 解决内存碎片问题  
2. 可以使用简单高效的碰撞分配器(Bump Allocator)  

但是现代的内存分配算法 (比如 Go Runtime 使用的基于 tcmalloc 的内存分配算法) 已经不存在内存碎片问题。而且碰撞分配器在单线程环境下可以做到简单高效，但是在多线程环境下需要使用锁机制进行同步。当然，也可以为每个线程准备一个可分配的内存缓存，这样在每个线程中使用内存缓存来分配内存，避免锁的性能问题。不过这样做这个碰撞分配器就会变得复杂。  
因此可以说在多线程环境下，使用紧凑型 GC 并不会带来实质性的性能提升。当然这并不是说使用紧凑型 GC 会有什么问题。

然后是分代 GC：  
分代 GC 依赖一个基本的假设：大部分对象 (或其他数据结构) 只使用一小段时间就不再被使用了，因此 GC 应该花费更多的时间或性能在最新创建的对象上，而不是频繁的检查所有的对象。

但是 Go 本身与上述的 GC 所依赖的假设或条件有些不同。比如使用了更现代化的内存分配算法。而且 Go 编译器将大部分的短暂使用的对象都是存储在栈空间中，然后利用逃逸分析 (Escape Analysis) 来将某些超出作用域的对象分配到堆空间(需要 GC 的内存空间)。因此分代 GC 对于 Go 来说不会有太大的提升。
    
分代 GC 通常是在一个 GC 暂停时间(Stop the world) 里快速的检查一下最新一代的对象内存，然后进行回收，这类 GC 以减少暂停时间为目标。但是 Go 语言使用了并发 GC，GC 暂停时间与任意一代的对象都没有关系。GO 认为在多线程环境中最好的办法是并行的运行 GC 和其他业务线程(GC 线程运行在单独的 CPU 核心，相对其他 GC 需要花费相对多一点的性能)，不暂停正常业务的运行，而不是去减少暂停时间。

分代 GC 的并行 GC 和降低 GC 的执行时间的方法对于 Go 而言仍然具有重大的借鉴意义，但是这些东西要在 Go 中得到应用还需要进行大量的测试。

目前 Go 更加倾向于基于单请求的内存管理策略（参考 [Request Oriented Collector (ROC) Algorithm](https://docs.google.com/document/d/1gCsFxXamW8RRvOe5hECz98Ftk-tcRRJcDFANj2VwCB0/view) [PDF](../assets/files/golang-gc-paper.pdf)）
