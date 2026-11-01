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
        _media_server_restart $service; or return
    end
    if set -q restart[1]
        echo 'Restarted services may need Local Network re-approval in System Settings > Privacy & Security > Local Network.' >&2
    end
    set -l uid (id -u)
    _media_server_source_update spoolman Donkie/Spoolman ~/Server/spoolman/app gui/$uid/local.spoolman http://127.0.0.1:7912/api/v1/info; or return
    _media_server_source_update haspelsync Rdiger-36/HaspelSync ~/Server/haspelsync/app gui/$uid/local.haspelsync http://127.0.0.1:4000/; or return
    _media_server_source_update seerr seerr-team/seerr ~/Server/media-server/seerr system/local.seerr http://127.0.0.1:5055/api/v1/status
end

function _media_server_restart --argument-names service
    echo "Restarting $service"
    if string match -q 'system/*' $service
        sudo launchctl kickstart -k $service
    else
        launchctl kickstart -k $service
    end
end

# Update a source-installed app to its latest GitHub release. <link> points to
# the current folder in releases/. The new release is built next to it, the data
# is backed up to backups/, and the link is switched back if the restarted
# service does not answer <url>. The previous release is kept for rollback.
function _media_server_source_update --argument-names name repo link service url
    set -l current (path resolve $link)
    set -l latest (gh release view -R $repo --json tagName -q .tagName); or return
    test (string replace -r '^v' '' (path basename $current)) = (string replace -r '^v' '' $latest); and return
    # gui/<uid> exists only while the user is logged in at the Mac, not over SSH.
    set -l domain (path dirname $service)
    if not launchctl print $domain >/dev/null 2>&1
        echo "$name: skipped $latest; launchd domain $domain is not available (nobody is logged in at the Mac)." >&2
        return
    end
    if not launchctl print $service >/dev/null 2>&1
        echo "$name: $service is not loaded in launchd." >&2
        return 1
    end
    echo "Updating $name "(path basename $current)" -> $latest"
    set -l root (path dirname $link)
    set -l releases (path dirname $current)
    set -l stage $releases/$latest
    # A failed earlier build may have left it behind.
    rm -rf $stage; and mkdir $stage; or return
    _media_server_build_$name $latest $stage $current; or return
    set -l backup $root/backups/$name-(path basename $current)-(date +%Y%m%d-%H%M%S)
    mkdir -p $backup; and _media_server_backup_$name $backup; or return
    set -l old_target (readlink $link)
    ln -sfn (path dirname $old_target)/$latest $link; or return
    if _media_server_restart $service; and _media_server_wait $url
        for release in $releases/*
            contains (path basename $release) $latest (path basename $current); or rm -rf $release
        end
        return
    end
    echo "$name: $latest did not answer at $url; switching back to $old_target. Data backup: $backup" >&2
    ln -sfn $old_target $link; and _media_server_restart $service
    return 1
end

function _media_server_wait --argument-names url
    for i in (seq 120)
        curl -fsS -o /dev/null -m 2 $url 2>/dev/null; and return
        sleep 1
    end
    return 1
end

# ~/Server/spoolman/venv, used by the service, links to app/.venv, so each release has its own.
function _media_server_build_spoolman --argument-names tag stage current
    gh release download $tag -R Donkie/Spoolman -p spoolman.zip -D $stage; or return
    unzip -q $stage/spoolman.zip -d $stage; and rm $stage/spoolman.zip; or return
    uv --directory $stage venv --quiet .venv; or return
    uv pip install --quiet --python $stage/.venv -r $stage/requirements.txt
end

function _media_server_build_haspelsync --argument-names tag stage current
    gh release download $tag -R Rdiger-36/HaspelSync --archive tar.gz -O $stage/source.tar.gz; or return
    tar -xzf $stage/source.tar.gz --strip-components 1 -C $stage; and rm $stage/source.tar.gz; or return
    env -C $stage npm ci --omit=dev --no-audit --no-fund; or return
    # Runtime files the app keeps next to its code.
    cp -R $current/printers $stage/
end

# Same steps as Seerr's Dockerfile, with the Node version its service runs.
function _media_server_build_seerr --argument-names tag stage current
    git clone --quiet --depth 1 --branch $tag https://github.com/seerr-team/seerr.git $stage; or return
    set -l pnpm (string match -rg '"packageManager": *"(pnpm@[^"]+)"' <$stage/package.json); or return
    set -lx PATH /opt/homebrew/opt/node@22/bin $PATH
    env -C $stage CYPRESS_INSTALL_BINARY=0 npx --yes $pnpm install --frozen-lockfile; or return
    env -C $stage npx --yes $pnpm build; or return
    rm -rf $stage/.next/cache
end

function _media_server_backup_spoolman --argument-names dest
    sqlite3 ~/Server/spoolman/data/spoolman.db ".backup '$dest/spoolman.db'"
end

function _media_server_backup_haspelsync --argument-names dest
    cp -R ~/Server/haspelsync/data $dest/
end

function _media_server_backup_seerr --argument-names dest
    set -l config ~/Library/Application\ Support/seerr
    sqlite3 $config/db/db.sqlite3 ".backup '$dest/db.sqlite3'"; and cp $config/settings.json $dest/
end
