# CrossLang：Emacs 中的中英翻译与双语写作

CrossLang 是一个离线优先的 Emacs 中英辅助插件。在 Org、普通文本或已有的 gptel 对话中输入中文、英文或混合文本，即可在原处查看译文，再决定是否写入正文。

它提供两种工作方式：**动态预览**默认不修改正文；**双语写作**在明确开启后自动维护译文。生成译文前，需要自行启动本地服务并加载文本模型；插件不会替你完成这些步骤。

```text
请核对交付日期。
Please check the delivery date.
```

## 选择预览或双语写作

| 方式 | 开关 | 翻译如何出现 | 是否修改正文 |
| --- | --- | --- | --- |
| 动态预览 | `SPC - SPC` | 停笔后发起请求，生成的译文显示在原文下方 | 不自动修改；`SPC - b` 确认后才写入双语 |
| 双语写作 | `SPC - w` | 自动写入下行译文；继续修改原文，更新同一份译文 | 修改；开启这个模式即授权其管理范围内的自动写入 |

这里的 `SPC -` 是**先按空格，再按减号**。默认接入已有 `revolt-map` 的空闲减号槽，在 Evil Normal 状态使用。没有这个 Leader 配置也可以使用，见后面的安装说明。

### 动态预览：先查看，再写回

在需要辅助的缓冲区按 `SPC - SPC` 开启动态预览，然后输入：

```text
Please check 交付日期，预算是 50 USD.
```

停止输入约一秒后，插件才开始异步请求本地模型。模型返回结果后，译文在原文下方对齐显示；实际等待时间取决于模型速度，无需每次手动触发。

- `SPC - v`：查看原文、完整候选和核对事项。
- `SPC - RET`：确认后只写回目标语言。
- `SPC - b`：确认后保留原文，并把完整译文写到下一行。
- `SPC - c`：取消当前候选。下一次编辑后才恢复自动生成。

预览是临时 Overlay，不是正文，不会被保存，也不占用撤销步骤。生成途中继续编辑会使旧请求失效；过期结果不能写回来。

### 双语写作：持续维护译文

把光标放到需要维护的原文行，按一次 `SPC - w`。例如原来只有：

```text
日期
```

生成后，正文变成两行：

```text
日期
Date
```

把上行改为“交付日期”后，插件会更新同一份下行译文，不会重复追加新行，也无需再次确认。模型返回前，原有译文仍保留，状态栏显示 `Pair·待更新`。

自动维护仅限于这次建立的配对：

- 只管理开启时光标所在的输入行，以及本次生成的译文。不会遍历整份文档。
- 不猜测相邻的既有英文是否是译文，不自动认领或覆盖它。
- 光标留在原文的编辑位置，周围正文保持原样。
- 手动修改译文、删除两份内容间的连接换行或执行撤销，会停止自动维护，保留正文和你的修改。
- 再按 `SPC - w` 关闭：两份正文保留，动态维护停止。如需改用预览，再按 `SPC - SPC`。
- 当前配对关系只在本次编辑会话中存在，重开文件不会自动恢复认领。

自动写作不是逐字即时翻译。默认采用一秒防抖，在短暂停笔后异步更新；模型运行慢时也不会阻塞你继续编辑。

## 中英双向如何判断

动态辅助使用简单、可预测的字符规则，不额外调用一个模型来识别语言：

| 输入 | 动态目标 |
| --- | --- |
| 中文 | 英文 |
| 纯英文 | 简体中文 |
| 中英混合 | 补成英文，保留独立写好的英文部分 |
| 只有数字、空白或标点 | 不触发 |

因此英文原文也可以保留在上行，中文译文出现在下行。它不声称能识别所有语种，也不会根据调用次数判断你的外语水平。

## 安装：独立配置，不接管你的 Emacs

### 依赖与兼容范围

- Emacs 29.1 或更新版本；目前在 Windows、Emacs 31.1 上实测。其他平台尚未做完整实机验证。
- Python 3，后端只使用标准库，不需要安装 Python 第三方包。
- 使用菜单时需要已有的 `pretty-hydra` 及其依赖 `hydra`、`dash`、`s`、`compat`。
- 使用 gptel 对话时，需要你已安装并配置好的 `gptel`。普通缓冲区不要求实际启动 gptel 会话。
- 生成译文需要一个已经运行、已经加载文本模型的本地语言服务，具体协议见下一节。
- 离线词典可选，需要另外准备兼容的 StarDict 资源。

本仓库不捆绑模型、词典或个人 Emacs 配置，不自动安装依赖。

### 1. 克隆仓库

```sh
git clone https://github.com/lovemoganna/crosslang.git ~/.emacs.d/site-lisp/crosslang
```

如果你的 `user-emacs-directory` 不在 `~/.emacs.d/`，把仓库放到自己的配置目录，或修改下方加载路径。Windows 可使用 PowerShell，并把克隆目标换成实际路径。

### 2. 在独立配置文件中加载

例如新建 `init-crosslang.el`，然后从自己的初始化文件引入它：

```emacs-lisp
(load (expand-file-name "site-lisp/crosslang/crosslang-init.el"
                        user-emacs-directory)
      nil t)

(setq crosslang-local-python "python"  ; 不在 PATH 时填写完整解释器路径
      crosslang-local-port 1234        ; 改为你实际运行的本地端口
      crosslang-local-model 'auto)
```

仓库里的 [`examples/init-crosslang.el`](examples/init-crosslang.el) 可以直接复制后调整。发布入口不会覆盖这些选项，也不会自动启动服务、下载模型或开启编辑模式。

### 3. 接入你的 Leader

如果你已经使用 `revolt-map` 作为 `SPC` 主键，插件会注册空闲的 `-` 槽；如果它已有其他命令，会停止注册并报告冲突，**不会覆盖原命令**。

使用其他 Leader 时，把同一个菜单接到你自己的键图即可：

```emacs-lisp
;; 在 my-leader-map 已存在的前提下：
(define-key my-leader-map (kbd "-") #'hydra-crosslang/body)
```

不使用 Leader 或 Evil 时，也可以选择一个未占用的入口：

```emacs-lisp
(global-set-key (kbd "C-c -") #'hydra-crosslang/body)
```

插件不把普通空格改成全局前缀。在 Evil Insert / Emacs 状态仍正常输入空格；按你原来的方式切回 Normal 状态，再使用 `SPC -`。

无需菜单也能使用：`M-x crosslang-live-mode` 开关动态预览，`M-x crosslang-pair-mode` 开关双语写作。

## 配置本地语言能力

### 本地模型服务

当前后端针对 LM Studio / Bionic 的本地接口实现，只访问回环地址 `127.0.0.1`：

- `GET /api/v0/models`：识别当前已经加载的文本模型。
- `POST /v1/chat/completions`：请求 JSON Schema 格式的候选或局部补丁。

**仅有一个通用 OpenAI 风格聊天接口还不够**：服务还需要兼容这里的模型状态接口和结构化响应要求。

先在本地服务中启动 API、显式加载一个文本模型，再把 `crosslang-local-port` 设置成对应端口。插件不负责服务启动、模型下载或加载。

```emacs-lisp
;; 使用唯一已加载的文本模型：
(setq crosslang-local-model 'auto)

;; 如果同时加载多个，显式指定服务返回的模型 ID：
;; (setq crosslang-local-model "your-loaded-model-id")

;; 只使用离线词典、不做模型生成：
;; (setq crosslang-local-model nil)
```

没有模型、服务不可用或返回不受支持的内容时，保留原文。动态模式遇到资源错误会停止，不会反复自动重试；准备好资源后再开启。

### 可选的离线词典

```emacs-lisp
(setq crosslang-local-dictionaries "/path/to/your/stardict-resources/")
```

默认查找仓库旁的 `dictionaries/` 目录。该目录不会随仓库发布。

目前支持 `.ifo`、`.idx` 和 `.dict` / `.dict.dz`，词义字段要求 `sametypesequence=m`。不支持的字段不会伪装成成功查询。词典适合词语和短语查询，不能替代上下文翻译模型。

## 常用按键

`SPC -` 打开分栏 Hydra；下表中的完整键序列都以它开始。菜单动作结束后退出，不持续占用你后续输入。

| 按键 | 用途 |
| --- | --- |
| `SPC - SPC` | 动态预览开关 |
| `SPC - w` | 双语正文自动维护开关 |
| `SPC - m` | 基础语言辅助开关 |
| `SPC - -` | 按草稿 / 阅读位置调用智能辅助 |
| `SPC - e` | 手动英文表达 |
| `SPC - d` | 词句释义，优先使用已安装词典 |
| `SPC - t` | 完整阅读翻译 |
| `SPC - v` | 原文、完整候选、片段对照与核对事项 |
| `SPC - RET` | 确认后替换为当前候选 |
| `SPC - b` | 确认后保留原文、把译文写入下一行 |
| `SPC - c` | 取消本次请求或候选 |
| `SPC - s` | 选择 `full` / `partial` / `on-demand` 辅助程度 |
| `SPC - x` | 有限本地语境开关 |
| `SPC - r` / `SPC - R` | 自愿开始 / 结束无提示回顾，不创建练习任务 |
| `SPC - o` | 关闭语言辅助；菜单入口仍保留 |
| `SPC - q` | 只退出菜单，不取消当前候选 |

详情窗口中，`a` 确认替换，`b` 确认分行写入，`q` 关闭并取消该结果。旧的 `C-c L` 手动键组仍兼容；`M--` 保持原生负数参数功能。

`partial` 要求明确选区，因此不能用于自动预览或双语自动写作。手动“英文表达”和阅读操作有各自目标设置；前面的中英自动识别规则用于动态请求。

## 哪些内容会被处理

- **gptel**：只处理原有会话最后的未发送草稿，不创建另一条会话，不自动发送，也不改变原发送键。
- **Org**：动态预览默认处理当前正文段落，排除标题、属性、表格和代码块等结构；明确的手动选区沿用手动操作规则。不执行 Babel。
- **其他可编辑 Mode**：动态预览只处理当前行，不自动读取整份文件。排除进程标记之前的输出和开头的只读提示符。
- **双语写作**：在上述保护范围之内，进一步收窄到开启时的输入行和它自己生成的译文。

不以 Major Mode 名称设置白名单，但只读内容、minibuffer 和没有可编辑文本的原始终端显示不会被强行改写。切换 Major Mode 会清理当前辅助状态，需在新 Mode 中重新开启。

自动请求默认最多处理 2,000 字符。你可以调整防抖与长度：

```emacs-lisp
(setq crosslang-live-delay 1.0
      crosslang-live-max-characters 2000)
```

不建议为追求逐字刷新而把等待时间压得很小：持续输入会使旧请求失效，实际响应仍受模型速度限制。

## 样式、撤销与编辑体验

译文统一继承主题的 `font-lock-string-face` 配色，使用独立的 `crosslang-translation-face`。原文颜色、字号和语法高亮不变。动态预览、详情和已知的正文译文使用相同的视觉语言，警示结果仍使用警示色。

正文样式是临时 Overlay：不增加标记字符、不把样式写进文件、不增加撤销步骤。手动编辑对应译文或关闭相关模式后移除。历史普通文字不会被猜测为译文，重开文件也不自动按语言重新着色。

如需换成自己习惯的颜色，可运行：

```text
M-x customize-face RET crosslang-translation-face
```

预览方式的手动写回始终需要确认。双语写作是单独授权的自动编辑模式；数值、币种、否定、条件、修订号和所有权等检查仍然存在，但这些保守规则不能证明翻译一定准确。

## 隐私与资源边界

原始交流内容默认不上传到在线服务。Python 后端固定使用回环地址，不使用代理，不接受重定向。

gptel 语境默认最多取草稿前最近一段回复、最多 1,500 字符，不读取整个历史或工具输出；可用 `SPC - x` 关闭。阅读释义使用当前句子的有限语境。普通缓冲区不会隐式带上其他文件或段落。

离线可用的前提是相关词典或模型已经在本机准备好。资源缺失时明确失败，不伪造译文。

## 测试与维护

基础测试不需要运行模型服务，不下载词典，不加载个人 `init.el`。Python 测试会在临时目录生成微型 StarDict 文件，测试结束后清理。

先准备测试依赖：`gptel`、`compat`、`evil` 及其依赖，以及 Hydra 菜单所需依赖。然后在仓库根目录运行：

```sh
python scripts/run_tests.py --emacs emacs
```

通过 `package.el` 安装的依赖会由测试初始化加载。若使用 Straight 等自定义目录，重复传入依赖路径：

```sh
python scripts/run_tests.py --emacs /path/to/emacs \
  --load-path /path/to/gptel \
  --load-path /path/to/compat \
  --load-path /path/to/evil \
  --load-path /path/to/goto-chg \
  --load-path /path/to/pretty-hydra \
  --load-path /path/to/hydra \
  --load-path /path/to/lv \
  --load-path /path/to/dash \
  --load-path /path/to/s
```

PowerShell 可把命令写成一行，或用反引号续行。只运行 Python 测试：

```sh
python -B -m unittest discover -s tests -p test_worker.py -v
```

目前基础回归包含 147 项 ERT 与 18 项 Python 测试，覆盖局部修改边界、双向判断、动态取消、双语自动写作、原生撤销、Leader 冲突和样式清理。测试提供器与生成词典只用于验证契约，不是产品中的备用翻译数据。

此前在已加载的本地模型上验证过双向生成及两次原文修订后的自动更新；基础测试通过不代表任意模型都能满足结构化输出要求。

### 模块结构

| 文件 | 职责 |
| --- | --- |
| `crosslang.el` | 请求、候选、语义检查、确认与写回事务 |
| `crosslang-live.el` | 防抖、动态方向、过期取消及作用范围 |
| `crosslang-pair.el` | 双语正文的所有权与自动维护 |
| `crosslang-ui.el` / `crosslang-style.el` | 临时预览、详情、主题配色及正文样式 |
| `crosslang-org.el` / `crosslang-gptel.el` | 编辑器与交流渠道范围适配 |
| `crosslang-local.el` / `local_worker.py` | 异步本地后端与离线资源 |
| `crosslang-leader.el` / `crosslang-hydra.el` | 已有 Leader 的菜单入口 |
| `crosslang-init.el` | 不启动模型、不开启模式的独立加载入口 |

## 常见问题

**菜单能打开，但没有译文。** 先确认开启了动态预览或双语写作，当前内容可编辑、没有活动选区；再确认 Python 路径、本地 API 端口及模型加载状态。

**提示没有加载模型。** 在本地服务中显式加载文本模型。只填写模型 ID 不会让插件替你加载它；多个模型同时加载时，请指定其中一个 ID。

**只想看到译文，不想它改正文。** 关闭 `SPC - w`，改用 `SPC - SPC`。双语正文模式关闭时保留已经写入的文本。

**改了英文后不再自动刷新。** 这是所有权保护：手动改写译文会停止自动维护。确认需要重新开始时，在原文行关闭后重新开启；插件不会擅自接管既有的相邻英文。

**为什么复杂句被拦截？** 规则发现了可能的数值、否定或条件变化。查看完整对照、澄清原文或自行编辑，不要把检查通过当作语义认证。

