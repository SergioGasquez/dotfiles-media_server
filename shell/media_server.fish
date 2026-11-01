# ~/.config/fish/conf.d/media_server.fish
# upup calls media_server_update after `brew upgrade`.

# Print launchd services (domain/label) still running Homebrew files that an
# upgrade removed. Root-owned processes cannot be inspected without sudo.
function stale_brew_services
    for plist in ~/Library/LaunchAgents/*.plist /Library/LaunchDaemons/*.plist
        set -l label (path change-extension '' (path basename $plist))
        set -l domain system
        string match -q "$HOME/*" $plist; and set domain gui/(id -u)
        set -l pid (launchctl print $domain/$label 2>/dev/null | awk '/^\tpid = /{print $3}')
        set -q pid[1]; or continue
        set -l files (for p in $pid (pgrep -P $pid); lsof -a -p $p -d txt,cwd -Fn 2>/dev/null; end | sed -n 's|^n\(/opt/homebrew/\)|\1|p')
        for file in $files
            if not test -e $file
                echo $domain/$label
                break
            end
        end
    end
end

# Stop after the first failed step.
function media_server_update
    set -l restart
    # Homebrew skips auto-updating casks by default; include the installed media apps.
    for app in jellyfin prowlarr radarr sonarr
        brew list --cask --versions $app >/dev/null 2>&1; or continue
        set -l outdated (brew outdated --cask --greedy --quiet $app); or return
        set -q outdated[1]; or continue
        brew upgrade --cask --greedy --yes $app; or return
        # Casks upgrade in place, so the stale check below cannot see them.
        test -f /Library/LaunchDaemons/local.$app.plist; and set -a restart system/local.$app
    end
    # Long-running services keep the old binary until restarted (e.g. HaspelSync
    # lost the printer after a node upgrade). Plists use opt/ paths, so a restart
    # picks up the new version.
    set -a restart (stale_brew_services)
    for service in (path sort -u $restart)
        echo "Restarting $service"
        if string match -q 'system/*' $service
            sudo launchctl kickstart -k $service; or return
        else
            launchctl kickstart -k $service; or return
        end
    end
    if set -q restart[1]
        echo 'Restarted services may need Local Network re-approval in System Settings > Privacy & Security > Local Network.' >&2
    end
    echo 'Not updated: source-installed Spoolman, HaspelSync, and Seerr (manual backup-aware update required).' >&2
end
