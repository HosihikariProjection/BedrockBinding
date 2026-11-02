# Hosihikari.Bindings.Bedrock

[English](README.md) | [简体中文](README.zh_hans.md)

Hosihikari 绑定项目的 **Bedrock / MCAPI** 互操作面：生成的、贴近原生风格的 **Interop** 与按符号分发的原生 **绑定垫片**。

本分支面向 **BDS 1.26.51.1**，数据来自 LeviLamina `ee049f1dc` 的头文件；`v1.21.3` 分支保留从载体调试符号生成的 1.21.3.01 面。

## 边界

- `Hosihikari.Bindings.Bedrock.Interop` 由 `HosihikariProjection/BindingGenerator` 从 LeviLamina `src/mc` 与 `ll/api` 头文件树的头文件级 IR 生成。它映照 MCAPI 声明：record 保留生成的包装类型，枚举声明投影为携带头文件枚举值的 C# 枚举，单层指针与引用返回变为类型化借用包装，`optional_ref<T>` 复用该路径，不受支持的成员保留带原因的 `NotSupportedException` stub；没有可用成员的类型保留类型身份并标记 `[Obsolete]`。ABI 值类型与 shim 加载器来自 `HosihikariProjection/BindingAbi`。
- `native/BindingShim/` 是 C ABI 投影，自包含：不包含游戏头文件，也不链接 import library。每个成员在运行期向预加载器（`pl_resolve_symbol`）查询其修饰名；查询入口通过 `GetModuleHandleW`/`dlsym` 动态取得，因此没有预加载器的进程里垫片也能加载，只是调用返回 `symbol was not resolved`。解析结果按函数缓存，每个名称只查找一次。
- 手写 Idiomatic 层延后；生成的 Interop 是当前公开的互操作面。

## 当前状态

- Interop：`src/Hosihikari.Bindings.Bedrock.Interop/Generated/` 下 9,146 个生成的 C# 文件。
- 绑定垫片：`native/BindingShim/generated/win-x64-server/bedrock/` 下 154,476 个函数。
- 覆盖：`win-x64-server` 配置绑定 12,080 个声明与 101,068 个成员。
- `scripts/headers-26.51.txt` 列出解析的 5,199 个头文件。从这些头文件可达的声明都会发射；布局与字段偏移来自前端的 AST record layout，只要头文件能证明，record 就保留字段。

shim 以 `--symbol-dispatch --resolve-by-name` 模式发射。支持的 ABI：

- 标量与枚举底层类型；
- `std::string` / `std::string_view` 的值与 const 引用；可变 `std::string` 引用会被原地改写——void 方法把文本作为返回值，其它方法保留自身返回值并通过 `ref string` 参数回报；`std::string&&` 实参由垫片持有的临时对象 `std::move` 传入；
- 单层 `T*` / `T&`，以 `void*` 传递；
- 按值 record：小的 `triviallyCopyable` record 走整数寄存器，较大 record 走栈上临时区；非 triviallyCopyable 的 record 通过按名解析的拷贝构造函数构造实参，析构非平凡时由被调方释放；无拷贝构造记录的平凡析构 record 按字节复制，但仍使用隐藏引用；
- 按值返回的签名省略默认模板实参时（如 `Bedrock::Result<T>`）会归一为已记录的特化 `Bedrock::Result<T, std::error_code>`；`GameplayHandlerResult<T>` 等模板返回由第二遍前端实例化，调用返回拥有型包装并可正常 `Dispose`。模板只有在头文件用数据成员或基类证明布局时才作为按值返回；重建的空壳会被拒绝，而不是按 1 字节定尺；
- `leveldb::Status` 返回来自载体固定的 leveldb 1.23 包，`regenerate.ps1` 把它作为外部根传给前端；枚举模板实参（`Bedrock::Result<T, ActorValidationError>`）与实参完整的 record 返回（`StreamableAssetSource`）由同一份 sizeof 预置实例化；
- 虚方法（含纯虚声明）按 IR 记录的槽位经对象 vftable 调用；纯虚方法没有实现符号，槽位是唯一路径；非纯虚方法优先走符号，符号未导出时回退到同一槽位（leveldb 与 WebRTC 的覆盖方法即是如此）；`Bedrock::Result` 特化在 1.26.51.1 中没有析构符号，`Dispose` 会释放结果缓冲，但不会释放错误载荷；
- 位域按存储位读写：bool、整数与枚举位域投影为标量属性，继承来的标志会出现在每个派生类上；
- 类型未投影的字段以只读 `nint` 暴露字段存储地址，属性名为 `<field>_Address`；
- `optional_ref<T>` 参数与返回使用存在标志；
- `std::vector<T>` 参数与按值返回，元素支持标量/枚举、字符串、单层指针（以 `nint[]` 传入），或 layout 已知且平凡析构的 record；引用与指针 vector 返回仍是借用句柄；
- `gsl::span<T>` 参数与返回：返回的 `{size, pointer}` span 转为数组；标量元素复制为数组，指针与 `gsl::not_null<T*>` 元素为 `nint[]`，平凡析构的 record 元素成为拥有型包装对象；
- `std::optional<T>` 参数与返回，支持标量、字符串与 trivially copyable record；record payload 使用 layout 兼容的 blob，返回的 record 成为拥有包装；
- `std::shared_ptr<T>` 参数与返回，由 shim holder 持有一个共享引用；`std::weak_ptr<T>` 返回锁定一次形成强快照，过期时为空。

map 需要具名 key/value 类型与匹配的 hash/equality functor，合并后的 IR 不携带这些信息。回调、variant、自定义拥有型包装，以及缺少可证明布局的 record 保留 Interop stub。

## 生成

重新生成只需要公开输入：一份 LeviLamina `ee049f1dc` 检出，以及用 LLVM 23.1.4 构建的生成器。预编译依赖来自 LeviLamina 构建所用的本地 xmake 包仓库。

```shell
powershell -File scripts/regenerate.ps1 `
  -LeviLaminaRoot C:\path\to\LeviLamina
```

脚本解析 `scripts/headers-26.51.txt`，以 `--symbol-dispatch --resolve-by-name` 发射，并更新 `src/`、`native/BindingShim/generated/` 与 `coverage/`。载体按值引用 `leveldb::Status`，而定义在载体源码根之外，因此脚本把固定 leveldb 1.23 包中的 `leveldb/status.h` 作为外部根加入解析。迭代发射器时可传 `-SkipFrontend -IrDirectory <dir>` 复用已有 IR。审查 diff 后运行 `python scripts/verify_generated.py`。

## 构建

```shell
dotnet build Hosihikari.Bindings.Bedrock.slnx -c Release
powershell -File native/BindingShim/build.ps1
```

生成的 shim 目录包含来自 `BindingAbi` 的 `hosihikari_abi.h`，原生构建因此自包含。shim 用 MSVC 构建，不需要 BDS 头文件或 import library。

## 运行时冒烟

`tests/runtime-smoke/` 是一个插件脚本：在真实服务器进程内加载垫片，校验两个静态访问器，构造 `HashedString`、`Core::Random` 与 `TextPacket` 后调用实例方法，并复制一个 `HashedString`、按值传入 `ExpressionNode::unregisterQueryFunction` 以校验拷贝构造 ABI。`scripts/run-runtime-smoke.ps1 -ServerRoot <目录>` 会构建、部署插件、启动服务器并要求 `result=OK`。

## 分发

两个 NuGet 包共用版本 `1.26.51-r0`：

- `Hosihikari.Bindings.Bedrock.Interop` —— 托管互操作；依赖 `Hosihikari.Bindings.Abi`。
- `Hosihikari.Bindings.Bedrock.Shim` —— 原生 Windows 垫片，位于 `runtimes/win-x64/native/`。

`publish.yml` 在 `v*` 标签上运行：构建并校验面、编译垫片、打包两个包，并用 `NUGET_API_KEY` secret 推送到 nuget.org。本地打包：

```shell
powershell -File native/BindingShim/build.ps1 -Output artifacts/native/Hosihikari.Bindings.Bedrock.Shim.dll
dotnet pack src/Hosihikari.Bindings.Bedrock.Interop/Hosihikari.Bindings.Bedrock.Interop.csproj -c Release -o artifacts/pack
dotnet pack src/Hosihikari.Bindings.Bedrock.Shim/Hosihikari.Bindings.Bedrock.Shim.csproj -c Release `
  -p:ShimDll=artifacts/native/Hosihikari.Bindings.Bedrock.Shim.dll -o artifacts/pack
dotnet nuget push artifacts/pack/*.nupkg --api-key <key> --source https://api.nuget.org/v3/index.json
```

## 生成源校验

`scripts/verify_generated.py` 校验来源信息、覆盖基线、shim 函数数、表版本、托管表与每个生成文件的哈希。CI 构建解决方案、运行校验器、用生成器验证提交的覆盖契约，并编译 Windows shim。

## 数据来源

shim 内嵌 MSVC 修饰名；这些名称与布局事实是生成的绑定数据，与生成器版本、IR manifest 哈希、载体提交与头文件数一起记录在 `coverage/provenance.json`。重新生成不需要也不包含任何专有游戏二进制或调试符号。

## 相关仓库

- `HosihikariProjection/BindingIr`：IR schema、模型、读写器与校验器。
- `HosihikariProjection/BindingAbi`：共享 ABI 值类型、加载器与原生头。
- `HosihikariProjection/BindingGenerator`：libTooling 前端与发射器。
- `HosihikariProjection/LeviLaminaBinding`：LeviLamina 互操作面。
- `HosihikariProjection/EndstoneBinding`：Endstone 互操作面。

## 许可证

LGPL-3.0-or-later，见 `LICENSE.md`。
