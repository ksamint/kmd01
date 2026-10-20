#!/usr/bin/env ruby

version, sha256 = ARGV
abort "usage: render-cask.rb VERSION SHA256" unless version && sha256

puts <<~RUBY
  cask "kmd" do
    version "#{version}"
    sha256 "#{sha256}"

    url "https://github.com/ksamint/kmd01/releases/download/v\#{version}/ksamint-MarkEdit-\#{version}.dmg"
    name "kmd"
    desc "Fast, native Markdown editor with Chinese, Japanese, and French support"
    homepage "https://github.com/ksamint/kmd01"

    livecheck do
      url :url
      strategy :github_latest
    end

    depends_on macos: :sequoia

    app "kmd.app"

    zap trash: [
      "~/Library/Application Scripts/art.apuch.ksamint.markedit.finder-extension",
      "~/Library/Application Scripts/art.apuch.ksamint.markedit.preview-extension",
      "~/Library/Application Scripts/group.art.apuch.ksamint.markedit",
      "~/Library/Containers/art.apuch.ksamint.markedit",
      "~/Library/Containers/art.apuch.ksamint.markedit.finder-extension",
      "~/Library/Containers/art.apuch.ksamint.markedit.preview-extension",
      "~/Library/Group Containers/group.art.apuch.ksamint.markedit",
      "~/Library/Preferences/art.apuch.ksamint.markedit.plist",
      "~/Library/Saved Application State/art.apuch.ksamint.markedit.savedState",
    ]
  end
RUBY
