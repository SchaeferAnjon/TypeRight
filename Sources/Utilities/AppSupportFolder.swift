//
//  AppSupportFolder.swift
//  TypeRight
//

import Foundation

/// The folder under ~/Library/Application Support that holds everything TypeRight stores. It is
/// named after the bundle identifier, like the typing coach's notebook, so TypeRight never shares
/// files with an installed copy of TextWarden.
enum AppSupportFolder {
    static let name = Bundle.main.bundleIdentifier ?? "com.typeright.app"
}
