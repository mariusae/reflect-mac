#!/bin/sh
# Fetches the fonts Prism bundles (SIL Open Font License, bar Go, which is
# BSD) into Frameworks/: Mona Sans, with Monaspace Xenon for code and Radon
# for its italic; Recursive's Linear statics; Go; and, from Google Fonts,
# Literata with JetBrains Mono, Source Serif 4 with Source Sans 3 and Source
# Code Pro, IBM Plex Sans with Plex Mono, Fraunces, Alegreya Sans, and Lato;
# and Paper Mono, for Lato's code. Files already there are kept.
set -e
cd "$(dirname "$0")/.."

# A file from a GitHub repository at a ref, through the API (which is also
# up when raw.githubusercontent.com isn't).
github_file() { # repo ref path out
  [ -s "$4" ] || curl -sSfL --retry 3 -H "Accept: application/vnd.github.raw" -o "$4" \
    "https://api.github.com/repos/$1/contents/$3?ref=$2"
}

mona=v2.0.27
out=Frameworks/monasans
mkdir -p "$out"
for face in Regular Italic Medium SemiBold Bold BoldItalic; do
  github_file github/mona-sans $mona "fonts/static/otf/MonaSans-$face.otf" "$out/MonaSans-$face.otf"
done
github_file github/mona-sans $mona OFL.txt "$out/OFL.txt"

version=v1.400
out=Frameworks/monaspace
mkdir -p vendor "$out"
zip=vendor/monaspace-static-$version.zip
for family in Xenon Radon; do
  for face in Regular Italic Bold BoldItalic; do
    if [ ! -s "$out/Monaspace$family-$face.otf" ]; then
      [ -f "$zip" ] || curl -sSfL -o "$zip" \
        "https://github.com/githubnext/monaspace/releases/download/$version/monaspace-static-$version.zip"
      unzip -qjo "$zip" "Static Fonts/Monaspace $family/Monaspace$family-$face.otf" -d "$out"
    fi
  done
done
github_file githubnext/monaspace $version LICENSE "$out/LICENSE"

rec=v1.085
dir=fonts/ArrowType-Recursive-1.085/Recursive_Desktop/separate_statics/OTF
out=Frameworks/recursive
mkdir -p "$out"
for kind in Sans Mono; do
  for face in Regular Italic Med SemiBold Bold BoldItalic; do
    github_file arrowtype/recursive $rec "$dir/Recursive${kind}LnrSt-$face.otf" "$out/Recursive${kind}LnrSt-$face.otf"
  done
done
github_file arrowtype/recursive $rec OFL.txt "$out/OFL.txt"

go=v0.46.0
out=Frameworks/gofont
mkdir -p "$out"
for face in Regular Italic Medium Bold Bold-Italic Mono Mono-Italic Mono-Bold Mono-Bold-Italic; do
  github_file golang/image $go "font/gofont/ttfs/Go-$face.ttf" "$out/Go-$face.ttf"
done
github_file golang/image $go LICENSE "$out/LICENSE"

# From Google Fonts' repository, at a commit: most as variable fonts, the
# serifs with optical sizes, which set them for text at text sizes and for
# display at headings'.
gf=9710da1eacb3be272583c3224dcb70f9da6eadbb
google_fonts() { # family-directory out file…
  dir=$1 out=Frameworks/$2
  shift 2
  mkdir -p "$out"
  for file in "$@"; do
    github_file google/fonts $gf "ofl/$dir/$(printf %s "$file" | sed 's/\[/%5B/g; s/\]/%5D/g')" "$out/$file"
  done
  # Each family's licence, by its name: some share a folder.
  github_file google/fonts $gf "ofl/$dir/OFL.txt" "$out/OFL-$dir.txt"
}
google_fonts literata literata 'Literata[opsz,wght].ttf' 'Literata-Italic[opsz,wght].ttf'
google_fonts jetbrainsmono jetbrainsmono 'JetBrainsMono[wght].ttf' 'JetBrainsMono-Italic[wght].ttf'
google_fonts sourceserif4 source 'SourceSerif4[opsz,wght].ttf' 'SourceSerif4-Italic[opsz,wght].ttf'
google_fonts sourcesans3 source 'SourceSans3[wght].ttf' 'SourceSans3-Italic[wght].ttf'
google_fonts sourcecodepro source 'SourceCodePro[wght].ttf' 'SourceCodePro-Italic[wght].ttf'
google_fonts fraunces fraunces 'Fraunces[SOFT,WONK,opsz,wght].ttf' 'Fraunces-Italic[SOFT,WONK,opsz,wght].ttf'
google_fonts alegreyasans alegreya AlegreyaSans-Regular.ttf AlegreyaSans-Italic.ttf AlegreyaSans-Light.ttf \
  AlegreyaSans-LightItalic.ttf AlegreyaSans-Medium.ttf AlegreyaSans-MediumItalic.ttf AlegreyaSans-Bold.ttf AlegreyaSans-BoldItalic.ttf
google_fonts lato lato Lato-Regular.ttf Lato-Italic.ttf Lato-Light.ttf Lato-LightItalic.ttf Lato-Bold.ttf \
  Lato-BoldItalic.ttf Lato-Black.ttf Lato-BlackItalic.ttf
# Lato's code in Paper Mono, from Paper's own repository.
paper=e6eaeceaef02e77e3db997711e07a16378de2bd7
for face in Regular Medium Bold; do
  github_file paper-design/paper-mono $paper "fonts/ttf/PaperMono-$face.ttf" "Frameworks/lato/PaperMono-$face.ttf"
done
github_file paper-design/paper-mono $paper OFL.txt Frameworks/lato/OFL-papermono.txt
google_fonts ibmplexsans plex 'IBMPlexSans[wdth,wght].ttf' 'IBMPlexSans-Italic[wdth,wght].ttf'
google_fonts ibmplexmono plex IBMPlexMono-Regular.ttf IBMPlexMono-Italic.ttf IBMPlexMono-Medium.ttf \
  IBMPlexMono-SemiBold.ttf IBMPlexMono-Bold.ttf IBMPlexMono-BoldItalic.ttf

echo "fonts in Frameworks/: $(ls Frameworks/*/*.[ot]tf | wc -l | tr -d ' ')"
