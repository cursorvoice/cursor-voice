cask "cursor-voice" do
  version "0.4.1"
  sha256 "4ff64017dc51fbd6a648fddf65e732a4db668dc9fed66ff23f5b01fc9a1a29bf"

  url "https://github.com/tottenabderrahmane1-create/cursor-voice/releases/download/v#{version}/CursorVoice-#{version}.dmg"
  name "Cursor Voice"
  desc "Voice-driven macOS assistant powered by the OpenAI Realtime API"
  homepage "https://github.com/tottenabderrahmane1-create/cursor-voice"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "CursorVoice.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/CursorVoice.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/CursorVoice",
    "~/Library/Preferences/com.cursorvoice.app.plist",
    "~/Library/Caches/com.cursorvoice.app",
    "~/Library/HTTPStorages/com.cursorvoice.app",
    "~/Library/Saved Application State/com.cursorvoice.app.savedState",
  ]
end
