class WifiUsage < Formula
  desc "Menu bar Wi-Fi usage per network, network switcher and iPhone hotspot wake-up"
  homepage "https://github.com/Kontaa5/Wifi-Usage"
  url "https://github.com/Kontaa5/Wifi-Usage/archive/refs/tags/v2.7.1.tar.gz"
  sha256 "68c644e6c39937cdf2c1f4d711b260cf1d8f022f2dbffa1b5d8df2ce7f32fde9"

  depends_on :macos

  def install
    # Baut die App mit swiftc aus den Command Line Tools (ad-hoc signiert, Bundle-ID fest)
    system "./build-app.sh", prefix/"Wifi Usage.app"

    # Startbefehl; die App richtet beim ersten Start ihren Autostart selbst ein
    (bin/"wifi-usage").write <<~SH
      #!/bin/bash
      exec open "#{opt_prefix}/Wifi Usage.app"
    SH
    chmod 0755, bin/"wifi-usage"
  end

  def caveats
    <<~EOS
      Einmal starten – die App richtet ihren Autostart danach selbst ein:
        wifi-usage

      Nach einem Update neu starten:
        launchctl kickstart -k gui/$(id -u)/at.datenmonitor.widget

      Beim ersten Start fragt macOS nach den Ortungsdiensten: bitte erlauben,
      sonst gibt macOS den WLAN-Namen nicht heraus.
    EOS
  end

  test do
    assert_predicate prefix/"Wifi Usage.app/Contents/MacOS/wifi-usage", :executable?
  end
end
