# DPReader: A Swift program to load Minecraft datapacks

## Usage

Add the following line to your `Package.swift` file:

```Swift
.package(url: "https://github.com/picawawa4000/dpreader-swift.git", branch: "master")
```

The library is named `DPReader`.

## Contribution

If for some reason you want to contribute something to this project, open a PR. As long as your changes are tested thoroughly enough, I will probably merge them at some point. However, beware: if you don't add tests for your changes, I will make ChatGPT do it.

## Bugs

If you find a bug (incorrect biomes, terrain, etc.), open an issue and state the exact circumstances that cause the bug (seed, datapacks, coordinates). I (or someone else) might get around to fixing it at some point.

## Supported data pack formats

Currently, DPReader is mainly geared towards data pack version 92.0, which corresponds to Minecraft version 25w44a. Because the code is rather messy, however, it is likely that some features only present in newer formats have crept in. Proper format control will be introduced as soon as I can figure out the cleanest way to implement it.
