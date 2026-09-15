cask "echo" do
  version "1.4.0"
  sha256 "486560bc9e974aee78efdfdabf3135905c0ff6aef17c7902f1c8eaed884c9448"

  url "https://github.com/alexiscreuzot/echo/releases/download/v#{version}/Echo.zip"
  name "Echo"
  desc "Send a specific app's audio into the iOS Simulator"
  homepage "https://github.com/alexiscreuzot/echo"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "Echo.app"

  zap trash: "~/Library/Preferences/com.alexiscreuzot.echo.plist"
end
