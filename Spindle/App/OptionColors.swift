//
//  OptionColors.swift
//  Spindle
//
//  Colours you picked for the built-in labels (Mood, Intro, Outro), as
//  palette indexes keyed "field:option". Tags, tempo groups and your own
//  fields keep their colour with the option itself.
//

import Observation
import SwiftUI

@Observable
final class OptionColors {
    static let shared = OptionColors()
    private(set) var picked: [String: Int] = [:]

    private init() {
        picked = (UserDefaults.standard.dictionary(forKey: "optionColors") as? [String: Int]) ?? [:]
    }

    func index(_ field: String, _ option: String) -> Int? { picked["\(field):\(option)"] }

    func color(_ field: String, _ option: String, default fallback: Color) -> Color {
        index(field, option).map { TagStore.palette[$0 % TagStore.palette.count] } ?? fallback
    }

    func set(_ field: String, _ option: String, _ index: Int) {
        picked["\(field):\(option)"] = index
        UserDefaults.standard.set(picked, forKey: "optionColors")
    }
}
