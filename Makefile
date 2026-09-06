.PHONY: build test app run clean lint

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

clean:
	rm -rf .build dist
