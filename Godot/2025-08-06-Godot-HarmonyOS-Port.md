---
layout: post
title: Godot 开发鸿蒙游戏教程
date: 2025-08-06 12:00:00 +0800
description: Godot 适配 HarmonyOS/OpenHarmony 进展，Godot 开发鸿蒙游戏教程
categories: Godot
tags: [Godot]
---

# Godot 开发鸿蒙游戏教程

## 概述
Godot 引擎已经完成鸿蒙系统的适配，支持 HarmonyOS 5 和 OpenHarmonry 5。

教程：https://www.bilibili.com/video/BV1DH4dzfEiv/

已支持的特性列表：

- Render
  - [x] Vulkan
- Input
  - [x] Touch Event
  - [x] Text Input
  - [x] Mouse Event
  - [x] Keyboard Event
- Audio
  - [x] Renderer
  - [x] Capturer
- DispayServer
  - [x] Portrait Layout
  - [x] Landscape Layout
  - [x] Window Resize
  - [x] IME Control
  - [x] Clipboard
- Scripts
  - [x] GDScript
  - [x] C# (Experimental)
- Network
  - [x] TCP/IP stack
  - [x] HTTP
  - [x] HTTPS (TLS)
- Export
  - [x] Export Project
  - [x] Run
  - [x] Debug

## 前置准备

| 内容                                                                        | 说明                                                   | 下载地址                                                                                                                         |
| --------------------------------------------------------------------------- | ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| Godot 源码（v4.4.1）                                                        | 1. 编译 Godot 导出模板<br/>2. 编译 Godot Editor        | https://github.com/kdada/godot.git                                                                                               |
| HarmonyOS 编译工具链<br/>（DevEco Studio/Command Line Tools for HarmonyOS） | 1. 编译 Godot 导出模板<br/>2. 编译 App<br/>3. 调试 App | https://developer.huawei.com/consumer/cn/download/                                                                               |
| OpenHarmony SDK（可选）                                                     | 1. 编译 Godot 导出模板                                 | https://gitee.com/openharmony/docs/blob/master/en/release-notes/OpenHarmony-v5.1.0-release.md#acquiring-source-code-from-mirrors |

说明：鸿蒙的编译工具链中已经包含了 OpenHarmony SDK，不需要额外下载。

## 编译流程

1. 下载 HarmonyOS 编译工具链：https://developer.huawei.com/consumer/cn/download/
   - 如果下载 DevEco Studio，直接安装即可
   - 如果下载 Command Line Tools for HarmonyOS，解压到任意路径即可
2. 下载 Godot 源码
   - `git clone https://github.com/kdada/godot`
3. 编译 Godot 导出模板
   - `scons platform=openharmony target=template_debug generate_bundle=yes module_mono_enabled=yes debug_symbols=yes OPENHARMONY_SDK_PATH="C:\Users\Kira\Downloads\ohos-sdk-windows_linux-public\ohos-sdk\windows"`
   - OPENHARMONY_SDK_PATH 路径：
     - DevEco Studio: `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony`
     - Command Line Tools for HarmonyOS: `{解压路径}\command-line-tools\sdk\default\openharmony`
     - OpenHarmony SDK: `{解压路径}\ohos-sdk\windows`

4. 编译 Godot Editor
   - `scons platform=windows target=editor module_mono_enabled=yes debug_symbols=yes`

## 开发和调试

1. 配置 Openharmony 工具链路径：【打开 Godot Editor】>【编辑器设置】>【导出】>【Openharmony】>【Openharmony Tool Path】
2. 将鸿蒙手机用 USB 线连接到电脑
3. 运行游戏
4. 使用 Godot 调试窗口进行调试

## 支持 C# 脚本需要额外的工作
1. 下载 OpenHarmony 的 dotnet 工具链
   - OpenHarmony.NET.Runtime: https://github.com/OpenHarmony-NET/OpenHarmony.NET.Runtime.git
   - PublishAotCross: https://github.com/OpenHarmony-NET/PublishAotCross.git
   - zig: https://ziglang.org/download/
2. 添加系统环境变量，将路径添加到环境变量的 PATH 中
   1. llvm 目录：C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native\llvm\bin
   2. zig 目录：C:\Users\Kira\Downloads\zig-x86_64-windows-0.15.0-dev.936+fc2c1883b
3. 在 Godot 项目中添加 dotnet targets
   1. `<Import Project="../OpenHarmony.NET.Runtime/runtime.targets" />`
   2. `<Import Project="../PublishAotCross/package/OpenHarmony.NET.PublishAotCross.targets" />`

## 社区 Proposal && PR
- Proposal: https://github.com/godotengine/godot-proposals/issues/12734
- PR: https://github.com/godotengine/godot/pull/108553