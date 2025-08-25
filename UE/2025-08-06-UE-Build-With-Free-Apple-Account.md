---
layout: post
title: 在 Windows 上用免费苹果开发者账号打包虚幻（Unreal Engine 4）项目
date: 2021-03-26 12:00:00 +0800
description: 在 Windows 上用免费苹果开发者账号打包虚幻（Unreal Engine 4）项目
categories: UE
tags: [UE]
---

# 背景

最近开始学习基于虚幻 4 的游戏开发，刚写完一个小 Demo，准备打包到手机上娱乐一下。然而天不遂人愿，虚幻引擎打包 Android 都没有问题，但是打包 iOS 就出现各种障碍，而且在谷歌和虚幻社区里也找不到有用的信息。不过好在最后都解决了，于是写下解决方案以供人参考。

# 环境准备
-  Windows：开发游戏的主力系统，各种硬件（主要是显卡）支持比 macOS 好很多。我的版本是 Windows 10。
  - Unreal Engine 4.26.1，必须是从源码构建的，因为下面要修改一部分构建工具的源码。
  - VisualStudio 2019 社区版
- macOS：虚幻引擎在 Windows 上不能编译 iOS 项目，所以要远程登陆到 macOS 进行构建，这个可以用虚拟机代替。我的版本是 macOS Big Sur 11.2.3
  - Xcode 12.4
  - 一个普通的 Apple ID，不需要注册 Apple Developer，你 iPhone 上登陆的那个就可以了。

以上系统和软件版本都是最新版本。

# 操作流程

## 在 macOS 上操作：

1. 在 Xcode -> Preferences -> Accounts 中登陆你的 Apple ID。
2. 在 Xcode 中新建一个 App 项目，这一步是为了拿到后续用于 UE4 打包用的 mobileprovision，拿到之后这个项目就没有用了。但是创建项目时以下几个关键字段必须要正确：
  - Product Name：你的 UE4 项目名
  - Team：选择你刚登陆的那个账号
  - Organization Identifier：你的域名倒过来写，比如 com.mydomain。这个和 Product Name 会一起构成 Bundle Identifier，用来生成 mobileprovision
3. 项目创建好了之后，插上你的 iPhone，在 Xcode 上运行，让这个空白 App 安装到你的 iPhone 里。这是为了给 mobileprovision 增加设备 ID。
4. 从 Keychain 中导出你的开发证书，证书名字是 Apple Development 开头的，导出后是一个 p12 文件。
5. 从 ~/Library/MobileDevice/Provisioning Profiles 找到刚创建的项目的 mobileprovision 文件。文件都是 UUID 命名的，不过可以通过预览看到真实名字，格式是： iOS Team Provisioning Profile: [项目 Bundle Identifier]。
6. 创建 ~/.keychain.password 文件，并在文件中写下你的 macOS 登陆密码，后面要用到。

## 在 Windows 上操作：

1. 打开 UE4 项目，在 编辑 -> 项目设置 -> 平台 -> iOS 中 导入条款（上面的 mobileprovision 文件） 和 导入证书（上面的 p12 文件），并打勾。
2. 在 Bundle Information -> 包辨识符 里写入刚刚的 Bundle Identifier，可以看到条款和证书的状态变成了 Valid。
3. 修改 iPhonePackager 和 UnrealBuildTool 代码（如果你已经有 Github 上 UnrealEngine 的源码权限，可以直接查看这个 [Commit](https://github.com/kdada/UnrealEngine/commit/6b5aeb87e6a1e4868a4cbf267de2e412a59304bc)），并重新生成这两个项目：

```C#
// Engine/Source/Programs/IOS/iPhonePackager/MobileProvisionUtilities.cs
    // 第 187 行，注释掉这几行代码：
    //if (TestProvision.ProvisionName == "iOS Team Provisioning Profile: " + CFBundleIdentifier)
    //{
    //    Program.LogVerbose("  Failing as provisioning is automatic");
    //    continue;
    //}

// Engine/Source/Programs/UnrealBuildTool/Platform/IOS/IOSToolChain.cs
    // 第 1816 行，修改判断条件为：
    if (Target.ImportProvision != null && !ProjectSettings.bAutomaticSigning) 
    // 第 1823 行，修改判断条件为：
    if (Target.ImportCertificate == null || ProjectSettings.bAutomaticSigning)
    // 第 1833 行，增加 else 语句：
    else
    {
        SigningCertificate = "Apple Development";
    }
    // 第 1965 行，修改 xcrun 执行语句：
    Writer.WriteLine("[[ -f \"$HOME/.keychain.password\" ]] && security unlock-keychain -p \"$(cat $HOME/.keychain.password)\" && /usr/bin/xcrun {0}", CmdLine);
 
// Engine/Source/Programs/UnrealBuildTool/Platform/IOS/UEBuildIOS.cs
    // 第 407 行，增加代码：
    this.bAutomaticSigning = true;
```

至此，全部工作已经完成，接下来就可以远程构建 ipa 包了。