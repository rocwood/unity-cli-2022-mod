# Unity 操作规范

本文规定 Agent 进行 Unity 开发时的工具选择、内容操作边界与验证要求。

## 1. 核心工具

- 统一通过 Unity CLI/Pipeline 与 Unity 交互，禁止使用 Unity MCP。
- 与 Unity 交互时必须使用 `unity-pipeline` 技能，并遵循其中的命令、参数、状态轮询和操作流程说明。
- 存在多个可连接的 Unity Editor 或开发版 Player 时，必须显式指定目标，避免误操作。
- 以当前实例的 `unity command` 列表为准，不假定 Pipeline 能力。

## 2. 操作边界

### 可直接编辑

- 普通 `.cs` 源码由 Agent 直接创建或修改。
- Shader、CSV、JSON、Markdown 等纯文本也可直接编辑，下文另有限制的除外。
- 涉及多个脚本或文本文件时，应先批量修改，再按文件类型统一执行必要的 Unity 刷新或编译，避免逐文件处理引发重复编译与重载。
- Pipeline 不可达时仅可编辑上述纯文本，不得修改序列化资源；未完成必要验证时必须明确说明。

### 必须使用 Pipeline

- 创建或修改场景、Prefab、Material、ScriptableObject、AnimationClip、AnimatorController、Timeline 等由 Unity 管理的序列化内容。
- 外部资源的 Unity 导入、导入设置和验证必须使用 Pipeline；批量导入时可先将源文件复制到目标目录。
- 移动、重命名、复制或删除 `Assets/` 下的既有文件和文件夹时必须使用 Pipeline，不得直接使用文件系统工具。
- 场景对象操作，包括 GameObject 的创建、删除、层级、Transform、组件及其序列化字段。
- Unity 工程设置，包括 Build Settings、Tags/Layers、Input、Quality、Graphics、Player Settings 等。
- 场景、Prefab、材质和视觉效果等应作为编辑器资产交付的内容，必须在编辑器中制作并持久化，提供必要的可调参数，不得以运行时临时生成替代。

### 禁止直接操作

- 禁止手动创建、修改或删除 `.meta`，不得将其中的 GUID 复用于其他资源。
- 禁止手动修改 Unity 序列化资源文件，如 `.unity`、`.prefab`、`.mat`、`.asset`、`.controller`、`.anim` 等。
- 禁止手动修改 Unity 生成内容或本地状态文件，如 `Library/`、`Temp/`、`Logs/`、`UserSettings/`、`*.csproj`、`*.sln` 等。
- 禁止以字节方式改写二进制资产。

## 3. 操作原则

- 同类目标批量查询、修改并统一验证，避免逐项往返。
- 更改序列化字段、组件类或程序集结构时，必须维护资源兼容与脚本绑定。
- 大范围重新导入、切换构建目标、构建 Player 或批量改写资源必须获得明确授权。
- 优先使用 `unity command` 的专用操作；无合适操作时，复杂 C# 使用 `run_script`，`eval` 仅用于单行表达式。通过 `run_script` 或 `eval` 执行的临时代码均应限于任务所需的最小范围，并按需处理 Undo、脏标记和保存。
- 批量导入时先检查路径和覆盖；无 `.meta` 的资源复制到目标目录后由 Unity 刷新导入；自带 `.meta` 的资源连同其 `.meta` 复制，并检查 GUID 冲突。

## 4. 验证与收尾

- 修改后执行与改动匹配的必要验证；非必要不运行全量测试。
- 视觉改动按批次截图，必要时分阶段验证，避免无信息重复。
- 区分 Console 的本轮新增日志与历史日志，避免误归因。
- Scene、Prefab 编辑或 Play Mode 操作结束后，保存有意义的修改，丢弃临时测试变更；不得擅自保存或丢弃用户已有的未保存内容。
