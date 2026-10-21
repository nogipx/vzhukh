package procinfo

import "testing"

func TestFromPath(t *testing.T) {
	cases := []struct{ path, appPath, name, exe string }{
		{"/Applications/Telegram.app/Contents/MacOS/Telegram", "/Applications/Telegram.app", "Telegram", "Telegram"},
		{
			"/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
			"/Applications/Google Chrome.app", "Google Chrome", "Google Chrome Helper",
		},
		{"/usr/bin/curl", "", "curl", "curl"},
		{"/Applications/Odd.app", "/Applications/Odd.app", "Odd", "Odd.app"},
	}
	for _, c := range cases {
		p := FromPath(1, c.path)
		if p.AppPath != c.appPath || p.Name != c.name || p.ExeName() != c.exe {
			t.Errorf("%s: got %+v exe %q", c.path, p, p.ExeName())
		}
	}
}
