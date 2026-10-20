//
//  AppVersion.swift
//  MarkEditMac
//
//  Created by cyan on 11/1/23.
//

import Foundation

/**
 [GitHub Releases API](https://api.github.com/repos/ksamint/kmd01/releases/latest)
 */
struct AppVersion: Decodable {
  struct Asset: Decodable {
    let name: String
    let browserDownloadUrl: String
  }

  let name: String
  let body: String
  let htmlUrl: String
  let assets: [Asset]?

  func isNewer(than currentVersion: String) -> Bool {
    let candidate = name.hasPrefix("v") ? String(name.dropFirst()) : name
    let current = currentVersion.hasPrefix("v") ? String(currentVersion.dropFirst()) : currentVersion
    return candidate.compare(current, options: [.numeric, .caseInsensitive]) == .orderedDescending
  }
}

/**
 ReleaseInfo.json added to GitHub release assets.

 It typically contains extra information for better updating experience.
 */
struct ReleaseInfo: Decodable {
  let minOSVer: String
}
