.PHONY: build test app run clean icon

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh release

# Rebuilds and relaunches the menu bar app.
run: app
	@pkill -x "Claude Bridge" 2>/dev/null || true
	@open "dist/Claude Bridge.app"

# Redraws Resources/AppIcon.icns. Only needed when the icon itself changes.
icon:
	swift scripts/make-icon.swift

clean:
	rm -rf .build dist
