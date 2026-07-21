SHELL := /bin/zsh

.PHONY: build test app run clean

build:
	swift build

test:
	swift test

app:
	zsh Scripts/package_app.sh

run: app
	open .build/Threadline.app

clean:
	swift package clean
	rm -rf .build/Threadline.app .build/Threadline.icns .build/Threadline.iconset
