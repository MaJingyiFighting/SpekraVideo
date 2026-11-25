import Foundation

enum FilmCategory: String, CaseIterable {
    case colorNegative = "彩色负片"
    case slidePositive = "彩色反转片"
    case blackAndWhite = "黑白负片"
}

struct FilmStockItem: Identifiable, Equatable {
    let id: String
    let displayName: String
    let shortName: String
    let category: FilmCategory
    let iso: Int
    let defaultPaperId: String
}

struct PrintMediumItem: Identifiable, Equatable {
    let id: String
    let displayName: String
    let shortName: String
    let isMonochrome: Bool
    let isCine: Bool
}

enum SpectralCatalog {
    // 全部 25 款胶片（17 款彩负 + 4 款反转片 + 4 款黑白负片）
    static let films: [FilmStockItem] = [
        // 柯达与富士民用/专业彩负
        FilmStockItem(id: "kodak_portra_160", shortName: "Portra 160", category: .colorNegative, iso: 160, defaultPaperId: "kodak_portra_endura"),
        FilmStockItem(id: "kodak_portra_400", shortName: "Portra 400", category: .colorNegative, iso: 400, defaultPaperId: "kodak_portra_endura"),
        FilmStockItem(id: "kodak_portra_800", shortName: "Portra 800", category: .colorNegative, iso: 800, defaultPaperId: "kodak_portra_endura"),
        FilmStockItem(id: "kodak_portra_800_push1", shortName: "Portra 800 +1", category: .colorNegative, iso: 1600, defaultPaperId: "kodak_portra_endura"),
        FilmStockItem(id: "kodak_portra_800_push2", shortName: "Portra 800 +2", category: .colorNegative, iso: 3200, defaultPaperId: "kodak_portra_endura"),
        FilmStockItem(id: "kodak_gold_200", shortName: "Gold 200", category: .colorNegative, iso: 200, defaultPaperId: "fujifilm_crystal_archive_typeii"),
        FilmStockItem(id: "kodak_ultramax_400", shortName: "Ultramax 400", category: .colorNegative, iso: 400, defaultPaperId: "fujifilm_crystal_archive_typeii"),
        FilmStockItem(id: "kodak_ektar_100", shortName: "Ektar 100", category: .colorNegative, iso: 100, defaultPaperId: "kodak_endura_premier"),
        FilmStockItem(id: "kodak_verita_200d", shortName: "Verita 200D", category: .colorNegative, iso: 200, defaultPaperId: "kodak_portra_endura"),
        FilmStockItem(id: "fujifilm_pro_400h", shortName: "Pro 400H", category: .colorNegative, iso: 400, defaultPaperId: "fujifilm_crystal_archive_typeii"),
        FilmStockItem(id: "fujifilm_c200", shortName: "Fuji C200", category: .colorNegative, iso: 200, defaultPaperId: "fujifilm_crystal_archive_typeii"),
        FilmStockItem(id: "fujifilm_xtra_400", shortName: "X-Tra 400", category: .colorNegative, iso: 400, defaultPaperId: "fujifilm_crystal_archive_typeii"),
        // 电影彩负与除碳胶片
        FilmStockItem(id: "cinestill_800t", shortName: "CineStill 800T", category: .colorNegative, iso: 800, defaultPaperId: "kodak_2383"),
        FilmStockItem(id: "kodak_vision3_500t", shortName: "Vision3 500T", category: .colorNegative, iso: 500, defaultPaperId: "kodak_2383"),
        FilmStockItem(id: "kodak_vision3_250d", shortName: "Vision3 250D", category: .colorNegative, iso: 250, defaultPaperId: "kodak_2383"),
        FilmStockItem(id: "kodak_vision3_200t", shortName: "Vision3 200T", category: .colorNegative, iso: 200, defaultPaperId: "kodak_2383"),
        FilmStockItem(id: "kodak_vision3_50d", shortName: "Vision3 50D", category: .colorNegative, iso: 50, defaultPaperId: "kodak_2383"),
        // 彩色反转片（正片直扫）
        FilmStockItem(id: "fujifilm_velvia_100", shortName: "Velvia 100", category: .slidePositive, iso: 100, defaultPaperId: "kodak_portra_endura"),
        FilmStockItem(id: "fujifilm_provia_100f", shortName: "Provia 100F", category: .slidePositive, iso: 100, defaultPaperId: "kodak_portra_endura"),
        FilmStockItem(id: "kodak_ektachrome_100", shortName: "Ektachrome 100", category: .slidePositive, iso: 100, defaultPaperId: "kodak_portra_endura"),
        FilmStockItem(id: "kodak_kodachrome_64", shortName: "Kodachrome 64", category: .slidePositive, iso: 64, defaultPaperId: "kodak_portra_endura"),
        // 黑白负片（配对伊尔福可变反差相纸）
        FilmStockItem(id: "kodak_tri_x_400", shortName: "Tri-X 400", category: .blackAndWhite, iso: 400, defaultPaperId: "ilford_multigrade_iv_rc"),
        FilmStockItem(id: "ilford_hp5_plus_400", shortName: "HP5 Plus 400", category: .blackAndWhite, iso: 400, defaultPaperId: "ilford_multigrade_iv_rc"),
        FilmStockItem(id: "kodak_tmax_100", shortName: "T-Max 100", category: .blackAndWhite, iso: 100, defaultPaperId: "ilford_multigrade_iv_rc"),
        FilmStockItem(id: "fujifilm_neopan_acros_100_ii", shortName: "Acros 100 II", category: .blackAndWhite, iso: 100, defaultPaperId: "ilford_multigrade_iv_rc")
    ]

    // 全部 9 款冲印介质（6 款彩色相纸 + 2 款电影拷贝正片 + 1 款黑白相纸）
    static let papers: [PrintMediumItem] = [
        PrintMediumItem(id: "kodak_portra_endura", displayName: "Kodak Portra Endura", shortName: "Portra Endura", isMonochrome: false, isCine: false),
        PrintMediumItem(id: "fujifilm_crystal_archive_typeii", displayName: "Fujifilm Crystal Archive II", shortName: "Fuji Crystal II", isMonochrome: false, isCine: false),
        PrintMediumItem(id: "kodak_endura_premier", displayName: "Kodak Endura Premier", shortName: "Endura Premier", isMonochrome: false, isCine: false),
        PrintMediumItem(id: "kodak_supra_endura", displayName: "Kodak Supra Endura", shortName: "Supra Endura", isMonochrome: false, isCine: false),
        PrintMediumItem(id: "kodak_ultra_endura", displayName: "Kodak Ultra Endura", shortName: "Ultra Endura", isMonochrome: false, isCine: false),
        PrintMediumItem(id: "kodak_ektacolor_edge", displayName: "Kodak Ektacolor Edge", shortName: "Ektacolor Edge", isMonochrome: false, isCine: false),
        PrintMediumItem(id: "kodak_2383", displayName: "Kodak Vision 2383", shortName: "Vision 2383", isMonochrome: false, isCine: true),
        PrintMediumItem(id: "kodak_2393", displayName: "Kodak Vision Premier 2393", shortName: "Premier 2393", isMonochrome: false, isCine: true),
        PrintMediumItem(id: "ilford_multigrade_iv_rc", displayName: "Ilford Multigrade IV RC", shortName: "Multigrade IV", isMonochrome: true, isCine: false)
    ]

    static let bwGrades: [String] = ["00", "0", "1", "2", "3", "4", "5"]
}

extension FilmStockItem {
    init(id: String, shortName: String, category: FilmCategory, iso: Int, defaultPaperId: String) {
        self.id = id
        self.displayName = shortName
        self.shortName = shortName
        self.category = category
        self.iso = iso
        self.defaultPaperId = defaultPaperId
    }
}
