---
layout: post
title: Centos 7 systemd 死锁问题分析
date: 2018-07-19 09:07:55 +0800
description: Centos 7 systemd 死锁问题分析
tags: [Linux]
---
 
### 问题分析

系统信息：
```
      KERNEL: /lib/debug/lib/modules/3.10.0-693.el7.x86_64/vmlinux
    DUMPFILE: ./systemd-hang-c221v38/vmcore  [PARTIAL DUMP]
        CPUS: 4
        DATE: Mon Jun 11 14:23:55 2018
      UPTIME: 13 days, 20:36:45
LOAD AVERAGE: 2.10, 2.10, 2.07
       TASKS: 244
    NODENAME: c221v38
     RELEASE: 3.10.0-693.el7.x86_64
     VERSION: #1 SMP Tue Aug 22 21:09:27 UTC 2017
     MACHINE: x86_64  (2199 Mhz)
      MEMORY: 8 GB
       PANIC: "SysRq : Trigger a crash"
```
处于 UN 状态的 Tasks：
```
#    PID    PPID  CPU       TASK        ST  %MEM     VSZ    RSS  COMM
crash> ps |grep UN
      1  1322389   3  ffff88017cd10000  UN   0.1  193608   6592  systemd
  1317113      2   3  ffff880029cd3f40  UN   0.0       0      0  [kworker/u8:1]
```
systemd 内核调用栈如下：
```
crash> bt -l ffff88017cd10000
PID: 1      TASK: ffff88017cd10000  CPU: 3   COMMAND: "systemd"
 #0 [ffff88017cd1bd10] __schedule at ffffffff816a8f45
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/kernel/sched/core.c: 2527
 #1 [ffff88017cd1bd78] schedule_preempt_disabled at ffffffff816aa3e9
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/kernel/sched/core.c: 3610
 #2 [ffff88017cd1bd88] __mutex_lock_slowpath at ffffffff816a8317
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/include/linux/spinlock.h: 301
 #3 [ffff88017cd1bde0] mutex_lock at ffffffff816a772f
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/arch/x86/include/asm/current.h: 14
 #4 [ffff88017cd1bdf8] mem_cgroup_write at ffffffff811f57e7
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/mm/memcontrol.c: 4638
 #5 [ffff88017cd1be68] cgroup_file_write at ffffffff8110aeef
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/kernel/cgroup.c: 2322
 #6 [ffff88017cd1bef8] vfs_write at ffffffff81200d2d
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/fs/read_write.c: 543
 #7 [ffff88017cd1bf38] sys_write at ffffffff81201b3f
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/fs/read_write.c: 566
 #8 [ffff88017cd1bf80] system_call_fastpath at ffffffff816b4fc9
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/arch/x86/kernel/entry_64.S: 444
    RIP: 00007f3ae83e385d  RSP: 00007ffff73b4350  RFLAGS: 00010246
    RAX: 0000000000000001  RBX: ffffffff816b4fc9  RCX: 0000000000001000
    RDX: 0000000000000003  RSI: 00007f3ae9bcf000  RDI: 0000000000000025
    RBP: 00007f3ae9bcf000   R8: 00007f3ae9bc1940   R9: 00007f3ae9bc1940
    R10: 0000000000000022  R11: 0000000000000293  R12: 0000000000000000
    R13: 0000000000000003  R14: 000055b2b54e10b0  R15: 0000000000000003
    ORIG_RAX: 0000000000000001  CS: 0033  SS: 002b
```
kworker/u8:1 内核调用栈如下：
```
crash> bt -l ffff880029cd3f40
PID: 1317113  TASK: ffff880029cd3f40  CPU: 3   COMMAND: "kworker/u8:1"
 #0 [ffff88018cf63ba0] __schedule at ffffffff816a8f45
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/kernel/sched/core.c: 2527
 #1 [ffff88018cf63c08] schedule_preempt_disabled at ffffffff816aa3e9
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/kernel/sched/core.c: 3610
 #2 [ffff88018cf63c18] __mutex_lock_slowpath at ffffffff816a8317
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/include/linux/spinlock.h: 301
 #3 [ffff88018cf63c70] mutex_lock at ffffffff816a772f
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/arch/x86/include/asm/current.h: 14
 #4 [ffff88018cf63c88] kmem_cache_destroy_memcg_children at ffffffff811f5fbe
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/mm/memcontrol.c: 3461
 #5 [ffff88018cf63cb0] kmem_cache_destroy at ffffffff811a6849
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/mm/slab_common.c: 282
 #6 [ffff88018cf63cd0] kmem_cache_destroy_memcg_children at ffffffff811f6009
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/mm/memcontrol.c: 3461
 #7 [ffff88018cf63cf8] kmem_cache_destroy at ffffffff811a6849
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/mm/slab_common.c: 282
 #8 [ffff88018cf63d18] nf_conntrack_cleanup_net_list at ffffffffc04075cb [nf_conntrack]
 #9 [ffff88018cf63d60] nf_conntrack_pernet_exit at ffffffffc040844d [nf_conntrack]
#10 [ffff88018cf63d88] ops_exit_list at ffffffff8157c473
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/net/core/net_namespace.c: 140
#11 [ffff88018cf63db8] cleanup_net at ffffffff8157d550
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/net/core/net_namespace.c: 451
#12 [ffff88018cf63e20] process_one_work at ffffffff810a881a
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/kernel/workqueue.c: 2252
#13 [ffff88018cf63e68] worker_thread at ffffffff810a94e6
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/include/linux/list.h: 188
#14 [ffff88018cf63ec8] kthread at ffffffff810b098f
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/kernel/kthread.c: 202
#15 [ffff88018cf63f50] ret_from_fork at ffffffff816b4f18
    /usr/src/debug/kernel-3.10.0-693.el7/linux-3.10.0-693.el7.x86_64/arch/x86/kernel/entry_64.S: 369
```

以上两个 task 的共同特点是在 mem\_cgroup\_write 和 kmem\_cache\_destroy\_memcg\_children 中都对 memcg\_limit\_mutex 进行的加锁操作，而且都卡在了这里。

查看 memcg\_limit\_mutex 的内存数据：
```
crash> p memcg_limit_mutex
memcg_limit_mutex = $7 = {
  count = {
    counter = -2
  },
  wait_lock = {
    {
      rlock = {
        raw_lock = {
          val = {
            counter = 0
          }
        }
      }
    }
  },
  wait_list = {
    next = 0xffff88018cf63c20,
    prev = 0xffff88017cd1bd90
  },
  owner = 0xffff880029cd3f40,
  {
    osq = {
      tail = {
        counter = 0
      }
    },
    __UNIQUE_ID_rh_kabi_hide1 = {
      spin_mlock = 0x0
    },
    {<No data fields>}
  }
}
```
通过内核源码可以知道 memcg\_limit\_mutex.count 的初始值为 1，现在上面的值为 -2，意味着有一个任务获取了锁，两个任务在等待队列中。并且 memcg\_limit\_mutex.owner 为 [kworker/u8:1]。

通过查看 memcg\_limit\_mutex.wait\_list 得到等待任务链表：
```
crash> struct mutex_waiter 0xffff88018cf63c20
struct mutex_waiter {
  list = {
    next = 0xffff88017cd1bd90,
    prev = 0xffffffff81a77e28 <memcg_limit_mutex+8>
  },
  task = 0xffff880029cd3f40
}

crash> struct mutex_waiter 0xffff88017cd1bd90
struct mutex_waiter {
  list = {
    next = 0xffffffff81a77e28 <memcg_limit_mutex+8>,
    prev = 0xffff88018cf63c20
  },
  task = 0xffff88017cd10000
}
```
从上面的结果可以看到， memcg\_limit\_mutex.wait\_list 中有两个 task，第一个是 [kworker/u8:1]，第二个是 systemd。

所以第一个结论是，systemd 确实卡在了这个锁上，并且 [kworker/u8:1] 获取了锁之后，还没有释放，就又锁了一次，导致死锁。

分析了另外一份 vmcore 之后，现象和结论都和上面一致。

[kworker/u8:1] 反复调用了 kmem\_cache\_destroy 和 kmem\_cache\_destroy\_memcg\_children，导致了死锁。

### 调试

下载 centos 7.4 内核源码 rpm 包： http://vault.centos.org/7.4.1708/os/x86\_64/Packages/kernel-3.10.0-693.el7.x86\_64.rpm。安装后在 ~/rpmbuild/SOURCES/linux-3.10.0-693.el7.tar.xz 取得内核源码。

在上面提到的相关函数中添加内核日志代码：

源码：mm/slab\_common.c:
```c
struct kmem_cache *
kmem_cache_create_memcg(struct mem_cgroup *memcg, const char *name, size_t size,
			size_t align, unsigned long flags, void (*ctor)(void *),
			struct kmem_cache *parent_cache)
{
	printk(KERN_DEBUG
			"kdbg: creating cache %s with cgroup %p and parent cache %p",
			name, memcg, parent_cache);
	struct kmem_cache *s = NULL;
	int err = 0;

	get_online_cpus();
	mutex_lock(&slab_mutex);

	if (!kmem_cache_sanity_check(memcg, name, size) == 0)
		goto out_locked;

	/*
	 * Some allocators will constraint the set of valid flags to a subset
	 * of all flags. We expect them to define CACHE_CREATE_MASK in this
	 * case, and we'll just provide them with a sanitized version of the
	 * passed flags.
	 */
	flags &= CACHE_CREATE_MASK;

	s = __kmem_cache_alias(memcg, name, size, align, flags, ctor);
	if (s) {
		printk(KERN_DEBUG "kdbg: cache %s(%p) shares %s with refcount %d and %s",
				name, s, s->name, s->refcount, is_root_cache(s)?"root":"nonroot");
		goto out_locked;
	}

	s = kmem_cache_zalloc(kmem_cache, GFP_KERNEL);
	if (s) {
		s->object_size = s->size = size;
		s->align = calculate_alignment(flags, align, size);
		s->ctor = ctor;

		if (memcg_register_cache(memcg, s, parent_cache)) {
			kmem_cache_free(kmem_cache, s);
			err = -ENOMEM;
			goto out_locked;
		}

		s->name = kstrdup(name, GFP_KERNEL);
		if (!s->name) {
			kmem_cache_free(kmem_cache, s);
			err = -ENOMEM;
			goto out_locked;
		}

		err = __kmem_cache_create(s, flags);
		if (!err) {
			s->refcount = 1;
			list_add(&s->list, &slab_caches);
			memcg_cache_list_add(memcg, s);
			printk(KERN_DEBUG "kdbg: allocated %s(%p) with refcount %d and %s",
					name, s, s->refcount, is_root_cache(s)?"root":"nonroot");
		} else {
			kfree(s->name);
			kmem_cache_free(kmem_cache, s);
		}
	} else
		err = -ENOMEM;

out_locked:
	mutex_unlock(&slab_mutex);
	put_online_cpus();

	if (err) {

		if (flags & SLAB_PANIC)
			panic("kmem_cache_create: Failed to create slab'%s'. Error %d\n",
				name, err);
		else {
			printk(KERN_WARNING "kmem_cache_create(%s) failed with error %d",
				name, err);
			dump_stack();
		}

		return NULL;
	}

	return s;
}

struct kmem_cache *
kmem_cache_create(const char *name, size_t size, size_t align,
		  unsigned long flags, void (*ctor)(void *))
{
	return kmem_cache_create_memcg(NULL, name, size, align, flags, ctor, NULL);
}
EXPORT_SYMBOL(kmem_cache_create);

void kmem_cache_destroy(struct kmem_cache *s)
{
	if (unlikely(!s))
		return;

	printk(KERN_DEBUG "kdbg: recycle cache %p which is %s", s,
			is_root_cache(s)?"root":"nonroot");

	/* Destroy all the children caches if we aren't a memcg cache */
	kmem_cache_destroy_memcg_children(s);

	get_online_cpus();
	mutex_lock(&slab_mutex);
	s->refcount--;
	if (!s->refcount) {
		list_del(&s->list);

		if (!__kmem_cache_shutdown(s)) {
			mutex_unlock(&slab_mutex);
			if (s->flags & SLAB_DESTROY_BY_RCU)
				rcu_barrier();

			memcg_release_cache(s);
			kfree(s->name);
			kmem_cache_free(kmem_cache, s);
			printk(KERN_DEBUG "kdbg: recycled cache %p", s);
		} else {
			list_add(&s->list, &slab_caches);
			mutex_unlock(&slab_mutex);
			printk(KERN_ERR "kmem_cache_destroy %s: Slab cache still has objects\n",
				s->name);
			dump_stack();
		}
	} else {
		mutex_unlock(&slab_mutex);
	}
	put_online_cpus();
}
```

源码：mm/memcontrol.c
```c
void memcg_release_cache(struct kmem_cache *s)
{
	struct kmem_cache *root;
	struct mem_cgroup *memcg;
	int id;

	/*
	 * This happens, for instance, when a root cache goes away before we
	 * add any memcg.
	 */
	if (!s->memcg_params)
		return;

	if (s->memcg_params->is_root_cache)
		goto out;

	memcg = s->memcg_params->memcg;
	id  = memcg_cache_id(memcg);

	root = s->memcg_params->root_cache;
	root->memcg_params->memcg_caches[id] = NULL;
	printk(KERN_DEBUG "kdbg: remove cache %p from parent %p with index %d",
			s, root, id);

	mutex_lock(&memcg->slab_caches_mutex);
	list_del(&s->memcg_params->list);
	mutex_unlock(&memcg->slab_caches_mutex);

	mem_cgroup_put(memcg);
out:
	kfree(s->memcg_params);
}

static void kmem_cache_destroy_work_func(struct work_struct *w)
{
	struct kmem_cache *cachep;
	struct memcg_cache_params *p;

	p = container_of(w, struct memcg_cache_params, destroy);

	cachep = memcg_params_to_cache(p);

	printk(KERN_DEBUG "kdbg: destroy worker for %p is called", cachep);

	/*
	 * If we get down to 0 after shrink, we could delete right away.
	 * However, memcg_release_pages() already puts us back in the workqueue
	 * in that case. If we proceed deleting, we'll get a dangling
	 * reference, and removing the object from the workqueue in that case
	 * is unnecessary complication. We are not a fast path.
	 *
	 * Note that this case is fundamentally different from racing with
	 * shrink_slab(): if memcg_cgroup_destroy_cache() is called in
	 * kmem_cache_shrink, not only we would be reinserting a dead cache
	 * into the queue, but doing so from inside the worker racing to
	 * destroy it.
	 *
	 * So if we aren't down to zero, we'll just schedule a worker and try
	 * again
	 */
	if (atomic_read(&cachep->memcg_params->nr_pages) != 0) {
		kmem_cache_shrink(cachep);
		if (atomic_read(&cachep->memcg_params->nr_pages) == 0)
			return;
	} else {
		printk(KERN_DEBUG "kdbg: destroy %p", cachep);
		kmem_cache_destroy(cachep);
	}
}

void kmem_cache_destroy_memcg_children(struct kmem_cache *s)
{
	struct kmem_cache *c;
	int i;
	char task_comm[TASK_COMM_LEN + 1];
	task_comm[TASK_COMM_LEN] = 0;

	if (!s->memcg_params)
		return;
	if (!s->memcg_params->is_root_cache)
		return;

	if (memcg_limit_mutex.owner == current) {
		/* Get task command name. */
		get_task_comm(task_comm, memcg_limit_mutex.owner);
		printk(KERN_EMERG "kdbg: %s dead lock with cache %p", task_comm, s);
	}

	/*
	 * If the cache is being destroyed, we trust that there is no one else
	 * requesting objects from it. Even if there are, the sanity checks in
	 * kmem_cache_destroy should caught this ill-case.
	 *
	 * Still, we don't want anyone else freeing memcg_caches under our
	 * noses, which can happen if a new memcg comes to life. As usual,
	 * we'll take the memcg_limit_mutex to protect ourselves against this.
	 */
	mutex_lock(&memcg_limit_mutex);
	for (i = 0; i < memcg_limited_groups_array_size; i++) {
		c = s->memcg_params->memcg_caches[i];
		if (!c)
			continue;

		/*
		 * We will now manually delete the caches, so to avoid races
		 * we need to cancel all pending destruction workers and
		 * proceed with destruction ourselves.
		 *
		 * kmem_cache_destroy() will call kmem_cache_shrink internally,
		 * and that could spawn the workers again: it is likely that
		 * the cache still have active pages until this very moment.
		 * This would lead us back to mem_cgroup_destroy_cache.
		 *
		 * But that will not execute at all if the "dead" flag is not
		 * set, so flip it down to guarantee we are in control.
		 */
		c->memcg_params->dead = false;
		cancel_work_sync(&c->memcg_params->destroy);

		printk(KERN_DEBUG "kdbg: parent %p cache %p index %d is %s existing %p",
				s, c, i, is_root_cache(s)?"root":"nonroot",
				s->memcg_params->memcg_caches[i]);
		kmem_cache_destroy(c);
	}
	mutex_unlock(&memcg_limit_mutex);
}
```

内核构建和安装：
```
# make -j8 bzImage
# installkernel 3.10.0-693.el7.x86_64 arch/x86/boot/bzImage System.map
```
如果使用 git 做了版本管理，make 会自动在版本号后面加上 "+"（例如 3.10.0-693.el7.x86_64+）。这时候需要使用如下命令编译去除：
```
# make LOCALVERSION= -j8 bzImage
```

重现死锁状态，得到日志：
```
Jul 19 12:13:14 c321v70 kernel: kdbg: destroy worker for ffff88021aa03a00 is called
Jul 19 12:13:14 c321v70 kernel: kdbg: destroy ffff88021aa03a00
Jul 19 12:13:14 c321v70 kernel: kdbg: recycle cache ffff88021aa03a00 which is nonroot
...
Jul 19 12:13:14 c321v70 kernel: kdbg: remove cache ffff88021aa03a00 from parent ffff8801f8b04b00 with index 775
Jul 19 12:13:14 c321v70 kernel: kdbg: recycled cache ffff88021aa03a00
Jul 19 12:13:14 c321v70 kernel: kdbg: parent ffff8801f8b04b00 cache ffff88021aa03a00 index 775 is root existing           (null)
Jul 19 12:13:14 c321v70 kernel: kdbg: recycle cache ffff88021aa03a00 which is root
Jul 19 12:13:14 c321v70 kernel: kdbg: kworker/u8:2 dead lock with cache ffff88021aa03a00
...
```

结论如下：
在某个时刻，释放 network namespace 的时候，调用 kmem\_cache\_destroy 删除关联的 root  kmem\_cache。同时进入 kmem\_cache\_destroy\_memcg\_children 删除关联的 memory cgroup 对应的 child kmem\_cache。在这个过程中，kmem\_cache\_destroy\_memcg\_children 对 memcg\_limit\_mutex 加锁，同时使用 cancel\_work\_sync 取消 child kmem\_cache 的自我清理工作。

但是这个时候由于 cancel\_work\_sync 的工作机制，在 child kmem\_cache 的自我清理工作已经开始的情况下，会等待工作完成才会返回。而清理工作完成后，会从 root kmem\_cache 的 children 数组里将自己删除。

但是 kmem\_cache\_destroy\_memcg\_children  已经进入了循环并取得了被清理的指针 c，此时 c 是一个 dangling pointer。
```c
	mutex_lock(&memcg_limit_mutex);
	for (i = 0; i < memcg_limited_groups_array_size; i++) {
		c = s->memcg_params->memcg_caches[i];
		if (!c)
			continue;
		c->memcg_params->dead = false;
		cancel_work_sync(&c->memcg_params->destroy);
		/*
		 * 问题就在这里，此时 s->memcg_params->memcg_caches[i] 已经为 NULL 了,
		 * 也就是说，不应该再对 c 进行清理操作。
		 */
		printk(KERN_DEBUG "kdbg: parent %p cache %p index %d is %s existing %p",
				s, c, i, is_root_cache(s)?"root":"nonroot",
				s->memcg_params->memcg_caches[i]);
		kmem_cache_destroy(c);
	}
	mutex_unlock(&memcg_limit_mutex);
```

触发这个 BUG 需要达成如下条件：
1. child kmem\_cache 进入自我清理状态
2. root kmem\_cache 加锁并进入循环状态，等待 child kmem\_cache 清理完成。
3. 调用 kmem\_cache\_destroy 时，child kmem\_cache 所处的内存又被申请出去使用，并且为 root。
