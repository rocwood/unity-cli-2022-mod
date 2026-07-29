# Unity CLI 2022 适配指南

> [认识 Unity CLI：在终端里操作 Unity](https://unity.com/cn/blog/meet-the-unity-cli)
>
> 开发越来越多地发生在终端——脚本里、CI 里，乃至 AI 代理手中。Unity CLI 顺势而生：一个快速、统一的 `unity` 命令，把 Unity 由外及内地带进终端——安装与管理编辑器、用脚本驱动运行中的编辑器，甚至无需重新编译即可在工程内执行 C#。

---

本仓库记录 Unity CLI 与 Unity 2022 的安装和适配方法。

- 部分网络环境下，安装地址会被重定向到国区 CDN，导致首次安装得到残血的旧版 `0.1.x`；可使用 CLI 自带的升级功能切换到指定版本。
- **本仓库不包含**修改版的 `com.unity.pipeline` 包，也不分发任何 Unity 二进制文件。`com.unity.pipeline` 在 Unity 2022 下的适配方式见下文。

---

## 🛠️ 安装 Unity CLI

### 1. 使用官方安装器

```
# macOS / Linux
curl -fsSL https://public-cdn.cloud.unity3d.com/hub/prod/cli/install.sh | UNITY_CLI_CHANNEL=beta bash
```

```
# Windows (PowerShell)
$env:UNITY_CLI_CHANNEL='beta'; irm https://public-cdn.cloud.unity3d.com/hub/prod/cli/install.ps1 | iex
```

### 2. 检查并更新版本

```
unity --version
```

如果得到的是旧版 `0.1.x`，说明官方安装地址可能被重定向到国区 CDN，可直接升级到已验证的版本：

```
unity upgrade -y --target 1.0.0-beta.3
```

升级完成后再次运行 `unity --version`，确认当前版本为 `1.0.0-beta.3`。

---

## 📦 安装 Pipeline 包

### ✅ 官方安装方法（适用于 Unity 6.0+）

```
# 默认作用于当前目录
unity pipeline install

# 或指定工程路径：
unity pipeline install --project-path /path/to/your/unity/project
```

### ⚠️ Unity 2022 安装方法

`com.unity.pipeline` 官方包面向较新的 Unity 6.0+ 版本，Unity 2022 工程无法通过 CLI 安装或在 Package Manager 中添加。

- 打开任意一款 AI 编程工具（如 Codex/Claude Code）
- 让 AI 从 Unity Registry 获取 `com.unity.pipeline` 源码，并放入工程的 `Packages/com.unity.pipeline` 目录
- 让 AI 修复 `PhysicsMaterial` 与 `Material.rawRenderQueue` 等 API 兼容性编译错误
- 让 AI 将 `Runtime/Plugins/CodeAnalysis` 下 `Microsoft.CodeAnalysis*`、`System.Collections.Immutable`、`System.Reflection.Metadata` 的 DLL `.meta` 转为兼容的v2格式
- 修复完成后即可在 Unity 2022 工程内正常使用。

> **注意：**目录名必须严格为 `com.unity.pipeline`，不能带任何 `@` 后缀（如 `com.unity.pipeline@a1b2c3d4`）；否则即使 Pipeline Server 能够启动，CLI 仍可能无法识别。感谢 [@SetoKaiba](https://github.com/SetoKaiba) 在 [Issue #1](https://github.com/rocwood/unity-cli-2022-mod/issues/1) 中反馈这一问题。

---

## 🤖 安装技能和操作规范

安装 `com.unity.pipeline` 后，让 AI：

1. 从包内提取 `.claude/skills/unity-pipeline`，安装到当前工程的技能目录。
2. 下载 [UNITY-GUIDE.md](https://raw.githubusercontent.com/rocwood/unity-cli-2022-mod/main/UNITY-GUIDE.md) 到工程根目录。
3. 在 `AGENTS.md` 或 `CLAUDE.md` 中加入：

   ```markdown
   进行 Unity 开发时，必须阅读并遵循 [UNITY-GUIDE.md](UNITY-GUIDE.md)。
   ```

---

## ⚖️ 免责声明

> 本仓库以 MIT 许可发布，但该许可仅适用于本仓库作者所做的原创内容和适配说明。Unity CLI 及其下载的二进制文件均为 Unity Technologies 的财产，仍受 Unity 适用的许可条款、服务条款及第三方许可证约束。
>
> 本仓库用于记录 Unity CLI 在 Unity 2022 环境下的兼容性与技术方案评估，不包含 Unity Pipeline 包本身，也不分发任何 Unity 二进制文件。文中安装和升级命令均使用 Unity 官方提供的安装器、CLI 及下载源。
>
> 本仓库无意替代 Unity Technologies 提供的任何官方软件或软件包。原始软件、脚本及其中的源代码、二进制文件和其他受保护材料，仍受其适用的许可条款、服务条款及第三方许可证约束。
>
> 本项目与 Unity Technologies 无关联，亦未获其赞助、认可或授权。“Unity”及相关名称、标识和商标均归 Unity Technologies 或其关联方所有；本仓库中对其的提及仅用于识别兼容目标，不构成任何商标使用许可。
>
> 本仓库按“现状”提供，不提供任何明示或默示保证，包括但不限于适销性、特定用途适用性、非侵权性、稳定性、安全性或与任何 Unity 版本的兼容性保证。使用者应自行测试，并自行承担使用本项目所产生的一切风险与责任。
