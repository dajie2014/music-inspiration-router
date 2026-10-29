import Foundation

/// MuScriptor 认得哪些乐器（2026-10-29 加「改改乐器」时整理）。
///
/// 模型内部把 128 个 MIDI 音色归成 36 组（35 类乐器 + 鼓），这一份就是那 36 组。
/// 它有两个用处：
///   ① 界面上给人勾 —— 「这首歌里其实有哪几样」；
///   ② 交给模型时写成 `--request-option instruments=...`，**勾了只出勾中的**。
///
/// ⚠️ 三句实话（写在这里，也写在界面上）：
///   · 勾上不是「让它更准」，是「让它只出这些」。漏勾一样，那样就没了。
///   · 一个都不勾 = 让它自己判断（默认就是这样，最省事）。
///   · 这张表里**没有中国民族乐器**（古筝、琵琶、二胡都不在）——
///     遇到民乐它会归到最近的西洋音色上，点名也治不了这个。
///
/// 依据：`audio.cpp/docs/models/muscriptor.md` 的 `instruments` 一栏，
/// 以及 `src/models/muscriptor/tokenizer.cpp` 里的组表。
struct MuScriptorInstrument: Identifiable, Hashable {
    /// 传给模型的英文名，也是事件 JSON 里 `instrument` 字段的值。
    let key: String
    /// 界面上说的中文。
    let chinese: String
    /// 分组，只为了让清单排得有条理。
    let group: String
    var id: String { key }
}

enum MuScriptorInstrumentCatalog {

    /// 分组顺序 —— 跟 GM 音色表的顺序大体一致，找起来顺手。
    static let groups = ["键盘", "吉他贝斯", "弦乐", "铜管", "木管", "打击", "合成与其它"]

    static let all: [MuScriptorInstrument] = [
        .init(key: "acoustic_piano", chinese: "原声钢琴", group: "键盘"),
        .init(key: "electric_piano", chinese: "电钢琴", group: "键盘"),
        .init(key: "chromatic_percussion", chinese: "钟琴类（钢片琴、马林巴）", group: "键盘"),
        .init(key: "organ", chinese: "风琴", group: "键盘"),

        .init(key: "acoustic_guitar", chinese: "原声吉他", group: "吉他贝斯"),
        .init(key: "clean_electric_guitar", chinese: "清音电吉他", group: "吉他贝斯"),
        .init(key: "distorted_electric_guitar", chinese: "失真吉他", group: "吉他贝斯"),
        .init(key: "acoustic_bass", chinese: "原声贝斯", group: "吉他贝斯"),
        .init(key: "electric_bass", chinese: "电贝斯", group: "吉他贝斯"),

        .init(key: "violin", chinese: "小提琴", group: "弦乐"),
        .init(key: "viola", chinese: "中提琴", group: "弦乐"),
        .init(key: "cello", chinese: "大提琴", group: "弦乐"),
        .init(key: "contrabass", chinese: "低音提琴", group: "弦乐"),
        .init(key: "orchestral_harp", chinese: "竖琴", group: "弦乐"),
        .init(key: "string_ensemble", chinese: "弦乐组", group: "弦乐"),

        .init(key: "trumpet", chinese: "小号", group: "铜管"),
        .init(key: "trombone", chinese: "长号", group: "铜管"),
        .init(key: "tuba", chinese: "大号", group: "铜管"),
        .init(key: "french_horn", chinese: "圆号", group: "铜管"),
        .init(key: "brass_section", chinese: "铜管组", group: "铜管"),

        .init(key: "soprano_and_alto_sax", chinese: "高音/中音萨克斯", group: "木管"),
        .init(key: "tenor_sax", chinese: "次中音萨克斯", group: "木管"),
        .init(key: "baritone_sax", chinese: "上低音萨克斯", group: "木管"),
        .init(key: "oboe", chinese: "双簧管", group: "木管"),
        .init(key: "english_horn", chinese: "英国管", group: "木管"),
        .init(key: "bassoon", chinese: "大管", group: "木管"),
        .init(key: "clarinet", chinese: "单簧管", group: "木管"),
        .init(key: "flutes", chinese: "长笛类（含短笛、竖笛）", group: "木管"),

        .init(key: "timpani", chinese: "定音鼓", group: "打击"),
        .init(key: "drums", chinese: "鼓组", group: "打击"),

        .init(key: "voice", chinese: "人声", group: "合成与其它"),
        .init(key: "synth_lead", chinese: "合成主音", group: "合成与其它"),
        .init(key: "synth_pad", chinese: "合成铺底", group: "合成与其它"),
        .init(key: "synth_strings", chinese: "合成弦乐", group: "合成与其它"),
        .init(key: "orchestra_hit", chinese: "管弦乐重击", group: "合成与其它"),
    ]

    static func instruments(in group: String) -> [MuScriptorInstrument] {
        all.filter { $0.group == group }
    }

    /// 英文名 → 中文名。界面把事件 JSON 里的 key 翻成人话时用。
    static func chinese(for key: String) -> String {
        all.first { $0.key == key }?.chinese ?? key
    }
}
