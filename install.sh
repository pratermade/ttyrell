cargo build --release
cp target/release/ttyrell ~/.local/bin
mkdir -p ~/.config/ttyrell
rm -rf ~/.config/ttyrell/lua
cp -r lua ~/.config/ttyrell/
