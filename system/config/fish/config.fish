# स्नेह Sneh fish config (managed). Your additions: ~/.config/fish/user.fish
fish_add_path -g ~/.local/bin /usr/share/sneh/bin
set -g fish_greeting
set -gx EDITOR nvim
set -gx VISUAL nvim
set -gx PAGER less
set -gx LESS -R

if status is-interactive
    starship init fish | source
    abbr -a st 'sne status'
    abbr -a a 'sne attach'
    abbr -a up 'sne update'
    abbr -a shot 'sne gui screenshot'
    abbr -a lg lazygit
    abbr -a y yazi
    abbr -a v nvim
    alias ls 'ls --color=auto --group-directories-first'
    alias ll 'ls -lh'
    # SSH welcome: one cheap line (no fastfetch on every login).
    if set -q SSH_CONNECTION; and not set -q TMUX
        set -l mem (awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%d/%d MB", (t-a)/1024, t/1024}' /proc/meminfo)
        printf '\e[38;2;239;178;164mस्नेह\e[0m %s · %s · load %s · %s\n' (cat /proc/sys/kernel/hostname) (uname -r) (cut -d' ' -f1 /proc/loadavg) $mem
        printf '\e[38;2;133;125;110m  sne attach → agents tmux · sne gui help · sne help\e[0m\n'
    end
end

test -f ~/.config/fish/user.fish; and source ~/.config/fish/user.fish
