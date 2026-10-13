#!/bin/zsh
# Builds Mastering-Swift-Concurrency.pdf from the guide's Markdown.
# Requires: pandoc, Google Chrome, Xcode command-line tools (swiftc).
set -e
T=${0:a:h}; G=${T:h:h}; W=$(mktemp -d); CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
cp $T/book.css $T/cover.html $T/dog_engraving.png $W/
xcrun swiftc -O $T/finish.swift -o $W/finish
render() {   # $1: optional pages.json for the table of contents
  python3 $T/build_md.py $G $W/book.md $1 >/dev/null
  pandoc $W/book.md -f markdown+raw_html+lists_without_preceding_blankline-implicit_figures -t html5 -s \
    --syntax-highlighting=pygments --css $W/book.css --embed-resources --standalone \
    --metadata pagetitle="Mastering Swift Concurrency" -o $W/interior.html
  "$CHROME" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf=$W/interior.pdf "file://$W/interior.html" 2>/dev/null
}
"$CHROME" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf=$W/cover.pdf "file://$W/cover.html" 2>/dev/null
render;                 $W/finish $W/interior.pdf $W/meta.json $W/pages.json < /dev/null   # pass 1: locate chapters
render $W/pages.json;   $W/finish $W/interior.pdf $W/meta.json $W/pages.json < /dev/null   # pass 2: TOC page numbers
$W/finish $W/interior.pdf $W/meta.json $W/pages.json $W/cover.pdf $G/Mastering-Swift-Concurrency.pdf < /dev/null
rm -rf $W
