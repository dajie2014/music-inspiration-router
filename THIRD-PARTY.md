# 用了别人的什么东西（模型与许可）

> 最后核对：**2026-10-25**。许可会变 —— 真要拿去用之前，请自己再点开原页面看一眼。

## 一句话

这个仓库**只是壳**。真正在出声音、出谱的，是下面这些**别人做的模型**，
我们一个都没有训练、也没有改。

> ⚠️ **其中三个是「非商用」许可：YuE2、SheetSage2、MERT。**
> ⇒ **自己用、自己听、自己发表作品，没问题；拿它做收费的产品或服务，不行**
> （除非按各自的原条款另外拿到商业授权）。

---

## 一、模型（5 个，真正在干活的）

| 模型 | 在本程序里干什么 | 谁做的 | 权重许可 | 能商用？ |
|---|---|---|---|---|
| **YuE2**（mlx-Yue） | 歌词 + 风格 → 整首歌（人声与伴奏） | Multimodal Art Projection（M·A·P，港科大等合作） | **CC BY-NC 4.0** | **❌ 不能** |
| **SheetSage2** | 一段录音 → 草稿谱（ABC） | ShugoAI（`audio.cpp`） | **CC BY-NC 4.0** | **❌ 不能** |
| **MuScriptor** | 一段录音 → 多轨 MIDI | ShugoAI（`audio.cpp`） | **没有找到明确标注**（权重来自 HF `audio-cpp/audio.cpp-gguf`） | **⚠️ 按「不能」处理** |
| **MERT** | 「RealAudio 重建」时提取音频特征 | m-a-p（MERT 系列） | **CC BY-NC 4.0** | **❌ 不能** |
| **HeartMuLa 3B**（audio.cpp 的 GGUF 量化版，2026-11-10 接上） | 歌词 + 英文风格标签 → 带人声的歌（不出谱） | HeartMuLa / 北京大学团队 | **Apache-2.0** | **✅ 可以** |

来源：

- YuE2 的许可原文：<https://yue2music.com/en/license>
  ——「Foundation Model Weights (CC BY-NC 4.0)」；推理代码是 Apache-2.0。
- SheetSage2 的模型卡：<https://huggingface.co/audio-cpp/SheetSage2-GGUF>（`license: cc-by-nc-4.0`）
- MERT 的模型卡：<https://modelscope.cn/models/m-a-p/MERT-v1-95M>（`license: cc-by-nc-4.0`）
- HeartMuLa 的仓库与许可：<https://github.com/HeartMuLa/heartlib>（Apache-2.0）；
  我们跑的是社区量化版（HF `audio-cpp/audio.cpp-gguf`），量化本身不改变许可。
- MuScriptor 的模型来源：本机 `audiocpp-bin/model_specs/muscriptor.json` 指向
  HF `audio-cpp/audio.cpp-gguf`；**那个页面的许可字段我们没取到**，所以按最保守的算。

> **「非商用」约束的是权重，不是你的作品。** YuE2 的许可页明确说：
> 生成的音频归你，个人创作用途可以商用（发流媒体、配乐等）。
> 但这句话我们**不替它担保** —— 你要真拿去商业发行，自己去读原文。

---

## 二、别人的代码与工具（不是模型，但也不是我们写的）

| 东西 | 干什么 | 许可 |
|---|---|---|
| **abc2xml / xml2abc**（Wim Vree） | MusicXML ↔ ABC 互转 | GPL 系 |
| **abcjs 6.5.2** | 浏览器里画谱、算播放时间线 | MIT |
| **MLX**（Apple） | 本机跑推理的框架 | MIT |
| 本仓库自己的代码（界面、壳、脚本） | —— | MIT，见 `LICENSE` |

⚠️ **GPL 那条要留神**：`abc2xml` 是 GPL 系，本程序是**当外部程序调用**它
（起一个进程、传文件），不是链进同一个程序里。真要分发二进制包，这条也得跟着核。

---

## 三、我们**没有**做的事

- **没有把任何模型权重放进这个仓库**：权重动辄几个 G，都靠 `scripts/fetch_models.py`
  在各自的机器上单独下载，仓库里只有下载脚本。
- **没有把用户的东西传出去**：全程离线，本机推理，不调用任何云端接口。
- **没有改模型**：只做调用与参数整理。

---

## 四、如果你要做成收费产品

按顺序解决这三件事，再谈别的：

1. **YuE2**：向 M·A·P 申请商业授权（或者换一个许可允许商用的模型）。
2. **SheetSage2 / MuScriptor**：同上；MuScriptor 连许可都没写清，先问作者。
3. **MERT**：同上；或者关掉「RealAudio 重建」这个功能。

在那之前，这个仓库的定位是：**一个人在自己电脑上做歌的工具**。
