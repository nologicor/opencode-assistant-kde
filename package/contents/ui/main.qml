import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtCore
import QtWebEngine
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.plasmoid
import org.kde.ksvg as KSvg

PlasmoidItem {
    id: root

    // The pet is the applet's own content (full representation): Plasma never
    // instantiates a compactRepresentation for an applet sitting on the desktop,
    // so putting the pet there left the widget empty.
    preferredRepresentation: fullRepresentation
    Plasmoid.backgroundHints: PlasmaCore.Types.ShadowBackground

    // A bit bigger than the pet so there's room to drag it around.
    Layout.minimumWidth: Plasmoid.configuration.petSize
    Layout.minimumHeight: Plasmoid.configuration.petSize * (208 / 192)
    Layout.preferredWidth: Plasmoid.configuration.petSize * 1.5
    Layout.preferredHeight: Plasmoid.configuration.petSize * (208 / 192) * 1.5

    // ---- config ----
    readonly property string serverHost: Plasmoid.configuration.hostname
    readonly property int serverPort: Plasmoid.configuration.port
    readonly property string serverUsername: Plasmoid.configuration.username || "opencode"
    readonly property bool loopbackHost: ["127.0.0.1", "localhost", "::1", "[::1]"].indexOf(serverHost) >= 0
    readonly property string serverPassword: Plasmoid.configuration.password || (loopbackHost ? unitPassword : "")
    readonly property string serverUrl: `http://${serverHost}:${serverPort}`

    // The web UI keeps its sign-in in a cookie. A WebEngineView without a named profile is
    // off-the-record, so that cookie dies with the widget and the password is asked again after
    // every restart. A named profile keeps it on disk instead.
    WebEngineProfile {
        id: webProfile
        storageName: "opencode-assistant"
        persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies
    }

    // Credentials are not put in the URL. The widget signs in the way a browser does: it mints
    // a one-time pairing code with the server password and opens /auth/connect/<code>, which
    // sets the 30-day session cookie before redirecting to the web UI.
    readonly property string webUrl: serverUrl + "/"

    // ---- runtime state ----
    property bool serverAlive: false
    property bool spawnAttempted: false
    property string petState: "idle"

    // The backend is started by a systemd unit that pins the server password. When the widget
    // has no password configured, read it from that unit so both sides always agree.
    property string unitPassword: ""

    // ---- popup size ----
    // The configuration is the single source of truth; a live drag only shadows
    // it through popupResizing. Never assign chatContent.width/height directly:
    // that destroys the binding to the configuration, and then neither the
    // settings dialog nor a later drag can resize the popup again.
    property bool popupResizing: false
    property int popupDragW: 0
    property int popupDragH: 0
    readonly property int popupW: popupResizing ? popupDragW : Plasmoid.configuration.popupWidth
    readonly property int popupH: popupResizing ? popupDragH : Plasmoid.configuration.popupHeight

    // The Layan theme uses an 8px dialog border. The popup draws the theme
    // background itself and insets its content by half that thickness, so the
    // visible border follows the system theme but stays 4px wide.
    readonly property int popupBorderWidth: 4
    readonly property bool alwaysOnTop: Plasmoid.configuration.alwaysOnTop !== false
    readonly property real webViewOpacity: Math.max(0.2, Math.min(1, (Plasmoid.configuration.webViewOpacity || 100) / 100))

    // resize gesture origin (screen coordinates) and starting size
    property real resizeOriginX: 0
    property real resizeOriginY: 0
    property int resizeStartW: 0
    property int resizeStartH: 0

    // ---- data dir (for logs + pets) — resolved from home (matches install.sh) ----
    // StandardPaths.writableLocation returns a QUrl in QML, so strip the file:// prefix.
    property string dataDir: {
        const p = StandardPaths.writableLocation(StandardPaths.GenericDataLocation).toString()
        const path = p.startsWith("file://") ? p.substring(7) : p
        return path + "/opencode-assistant-kde"
    }

    // curl reads the server password from this private config file, so it never
    // appears in the process arguments.
    readonly property string authFile: dataDir + "/curl-auth.conf"

    // ---- pet source: data dir first, package fallback ----
    property url petSource: Qt.resolvedUrl("pets/" + Plasmoid.configuration.petId + "/spritesheet.webp")

    // Hidden Image to probe whether the data-dir spritesheet exists
    Image {
        id: petChecker
        source: "file://" + root.dataDir + "/pets/" + Plasmoid.configuration.petId + "/spritesheet.webp"
        visible: false
        cache: false
        onStatusChanged: {
            if (status === Image.Ready) {
                root.petSource = source
            } else if (status === Image.Error) {
                root.petSource = Qt.resolvedUrl("pets/" + Plasmoid.configuration.petId + "/spritesheet.webp")
            }
        }
    }

    // ---- DataSource: spawn / kill commands ----
    Plasma5Support.DataSource {
        id: execSource
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source)
        }
    }

    // ---- DataSource: health check ----
    Plasma5Support.DataSource {
        id: healthSource
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source)
            const code = typeof data["stdout"] === "string" ? data["stdout"].trim() : ""
            root.serverAlive = (code === "200")
        }
    }

    // ---- DataSource: pairing code for the embedded web UI ----
    Plasma5Support.DataSource {
        id: pairSource
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source)
            const out = typeof data["stdout"] === "string" ? data["stdout"] : ""
            const match = /"code":"([^"]+)"/.exec(out)
            finishWebUi(match ? match[1] : "")
        }
    }

    // ---- DataSource: pet state polling ----
    Plasma5Support.DataSource {
        id: stateSource
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source)
            const body = typeof data["stdout"] === "string" ? data["stdout"] : ""
            root.petState = parseState(body)
        }
    }

    // ---- DataSource: server password of the backend unit ----
    Plasma5Support.DataSource {
        id: unitSource
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source)
            const out = typeof data["stdout"] === "string" ? data["stdout"] : ""
            const match = /OPENCODE_SERVER_PASSWORD=(\S+)/.exec(out)
            if (match) {
                root.unitPassword = match[1]
                console.log("[assistant] backend password taken from the systemd unit")
                root.refreshAuthFile()
            }
        }
    }

    // Writes the curl auth file from the systemd unit without putting the
    // password on any command line.
    Plasma5Support.DataSource {
        id: authFileSource
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source)
        }
    }

    // ---- timers ----
    Timer {
        id: healthTimer
        interval: 3000
        repeat: true
        onTriggered: pollHealth()
    }

    Timer {
        id: stateTimer
        interval: 3000
        repeat: true
        onTriggered: pollState()
    }

    // Last resort when no password is available to sign in with.
    Timer {
        id: fallbackTimer
        interval: 3000
        onTriggered: {
            if (root.webLoaded || !root.serverAlive) return
            root.webLoaded = true
            console.log("[assistant] no server password; opening web UI without sign-in")
            if (webView) webView.url = root.webUrl
        }
    }

    // ---- helpers ----
    function homeDir() {
        const p = StandardPaths.writableLocation(StandardPaths.HomeLocation).toString()
        return p.startsWith("file://") ? p.substring(7) : p
    }

    function opencodeBin() {
        const home = homeDir()
        return `${home}/.opencode/bin/opencode`
    }

    // Rebuild the private curl auth file from the unit. The password is never
    // part of this command line: systemctl's output is piped through sed.
    function refreshAuthFile() {
        const cmd = `umask 077; mkdir -p "${dataDir}"; printf 'user = "opencode:%s"\\n' "$(systemctl --user show opencode-web.service -p Environment --value | sed -n 's/.*OPENCODE_SERVER_PASSWORD=\\([^ ]*\\).*/\\1/p')" > "${authFile}"; chmod 600 "${authFile}"`
        authFileSource.connectSource(cmd)
    }

    // Prefer the 0600 curl config file so the password never appears in argv.
    // A password typed into the widget still has to use -u for now.
    function curlAuthArg() {
        if (Plasmoid.configuration.password) {
            return `-u "${serverUsername}:${Plasmoid.configuration.password}" `
        }
        if (root.unitPassword && root.loopbackHost) {
            return `-K "${root.authFile}" `
        }
        return ""
    }

    function spawnServer() {
        if (spawnAttempted) return
        spawnAttempted = true

        const home = homeDir()
        const port = Plasmoid.configuration.port
        // A spawned server is always local, even if the settings point at a
        // remote host.
        const host = "127.0.0.1"
        const username = Plasmoid.configuration.username
        const password = Plasmoid.configuration.password
        const logPath = dataDir + "/opencode-web.log"
        const bin = opencodeBin()

        // Clean environment: unset desktop-app leftovers that force auth / disable web UI
        // Then set username/password if provided
        let envCmd = `env -u OPENCODE_DISABLE_EMBEDDED_WEB_UI -u OPENCODE_CLIENT -u XDG_STATE_HOME`
        if (username && username !== "opencode") {
            envCmd += ` OPENCODE_SERVER_USERNAME="${username}"`
        }
        if (password && password !== "") {
            envCmd += ` OPENCODE_SERVER_PASSWORD="${password}"`
        } else if (root.unitPassword) {
            envCmd += ` OPENCODE_SERVER_PASSWORD="$(sed -n 's/^user = "opencode:\\(.*\\)"$/\\1/p' "${root.authFile}" 2>/dev/null)"`
        }
        const cmd = `umask 077; BIN="${bin}"; [ -x "$BIN" ] || BIN="${home}/.local/bin/opencode"; [ -x "$BIN" ] || BIN="$(command -v opencode || echo opencode)"; ${envCmd} setsid nohup "$BIN" serve --hostname ${host} --port ${port} > "${logPath}" 2>&1 &`
        execSource.connectSource(cmd)
        console.log("[assistant] spawn: opencode serve --hostname", host, "--port", port, root.serverPassword ? "(auth)" : "(no auth)")
    }

    function pollHealth() {
        const cmd = `curl -s -o /dev/null -w "%{http_code}" --max-time 2 ${root.curlAuthArg()}"${serverUrl}/"`
        healthSource.connectSource(cmd)
    }

    function pollState() {
        if (!serverAlive) return
        // /session serves the web UI shell; the session list lives under /api/session.
        const cmd = `curl -s --max-time 2 ${root.curlAuthArg()}"${serverUrl}/api/session"`
        stateSource.connectSource(cmd)
    }

    function parseState(body) {
        try {
            const payload = JSON.parse(body)
            const sessions = Array.isArray(payload) ? payload : payload.data
            if (!Array.isArray(sessions) || sessions.length === 0) return "idle"
            const now = Date.now()
            let latest = 0
            for (const s of sessions) {
                const t = s.time && s.time.updated ? s.time.updated : 0
                if (t > latest) latest = t
            }
            if (latest > 0 && (now - latest) < 3000) return "streaming"
            return "idle"
        } catch (e) {
            return "idle"
        }
    }

    function openWeb() {
        positionDialogAtPet()
        chatDialog.visible = true
        if (!serverAlive && !spawnAttempted) {
            spawnServer()
        }
        openWebUi()
    }

    // Bring an already-open popup back to the front without recreating it.
    function raiseWeb() {
        if (!chatDialog || !chatDialog.visible) return
        chatDialog.requestActivate()
        chatDialog.raise()
    }

    // PlasmaQuick turns a Normal dialog into a Dock when the stay-on-top flag
    // is set, so the role and flag must be applied in the right order.
    function applyWindowMode() {
        if (!chatDialog) return
        if (root.alwaysOnTop) {
            chatDialog.type = PlasmaCore.Dialog.AppletPopup
            chatDialog.flags = Qt.Dialog | Qt.WindowStaysOnTopHint
        } else {
            chatDialog.flags = Qt.Dialog
            chatDialog.type = PlasmaCore.Dialog.Normal
        }
    }

    // Sign in before showing the UI: the app shell does not reliably consume ?auth_token=, and a
    // plain load lands on the "Authenticate" screen. Minting a pairing code and opening its
    // /auth/connect link sets the session cookie, exactly like `opencode pair` in a browser.
    property bool webLoaded: false
    property bool pairing: false

    function openWebUi() {
        if (root.webLoaded || root.pairing || !root.serverAlive) return
        // Only pair while the popup is open: codes are single-use and expire after five minutes,
        // and a hidden WebEngineView may defer the navigation until it is shown.
        if (!chatDialog || !chatDialog.visible) return
        if (!root.serverPassword) {
            // The password is read asynchronously; give it a moment before showing a sign-in screen.
            fallbackTimer.start()
            return
        }
        fallbackTimer.stop()
        root.pairing = true
        const cmd = `curl -s --max-time 3 ${root.curlAuthArg()}-X POST "${root.serverUrl}/api/pair"`
        pairSource.connectSource(cmd)
    }

    function finishWebUi(code) {
        root.pairing = false
        if (!webView) return
        root.webLoaded = true
        if (!code) {
            console.log("[assistant] pairing code not issued; opening web UI without sign-in")
            webView.url = root.webUrl
            return
        }
        console.log("[assistant] opening web UI through the pairing link")
        webView.url = root.serverUrl + "/auth/connect/" + code
    }

    // ---- popup resizing ----
    // main.xml caps both dimensions at 2000; also keep the popup inside the screen.
    function clampPopupWidth(w) {
        const scr = root.screenGeometry
        const lim = Math.min(2000, scr && scr.width > 0 ? scr.width - 16 : 2000)
        return Math.round(Math.max(320, Math.min(w, Math.max(320, lim))))
    }

    function clampPopupHeight(h) {
        const scr = root.screenGeometry
        const lim = Math.min(2000, scr && scr.height > 0 ? scr.height - 16 : 2000)
        return Math.round(Math.max(240, Math.min(h, Math.max(240, lim))))
    }

    function beginPopupResize(g) {
        resizeOriginX = g.x
        resizeOriginY = g.y
        resizeStartW = popupW
        resizeStartH = popupH
        popupDragW = resizeStartW
        popupDragH = resizeStartH
        popupResizing = true
    }

    // The grips are anchored to the edges, so they move while the popup grows —
    // only screen coordinates give a stable reference for the drag delta.
    function updatePopupResize(g, horizontal, vertical) {
        if (!popupResizing) return
        if (horizontal) popupDragW = clampPopupWidth(resizeStartW + (g.x - resizeOriginX))
        if (vertical) popupDragH = clampPopupHeight(resizeStartH + (g.y - resizeOriginY))
    }

    function commitPopupSize() {
        if (!popupResizing) return
        // Store first, drop the drag override second: popupW/popupH keep the same
        // value across the handover, so the popup does not flicker back.
        Plasmoid.configuration.popupWidth = popupDragW
        Plasmoid.configuration.popupHeight = popupDragH
        popupResizing = false
        positionDialogAtPet()
    }

    // Place the chat dialog next to the pet without covering it: above the head
    // first (speech bubble), then below its feet, then to either side. Only when
    // none of those fit on screen does it fall back to overlapping the pet.
    function positionDialogAtPet() {
        if (!pet) return

        const gap = 8
        const scr = root.screenGeometry
        // dialog window size = content + themed margins (dialog may be hidden,
        // so chatDialog.width isn't synced yet — compute it explicitly)
        const m = chatDialog.margins
        const w = chatContent.width + (m ? m.left + m.right : 0)
        const h = chatContent.height + (m ? m.top + m.bottom : 0)

        // pet rectangle in screen coordinates
        const tl = pet.mapToGlobal(0, 0)
        const petW = pet.width
        const petH = pet.height

        const minX = scr.x + 4
        const maxX = scr.x + scr.width - w - 4
        const minY = scr.y + 4
        const maxY = scr.y + scr.height - h - 4
        const clamp = (v, lo, hi) => Math.max(lo, Math.min(v, hi))

        // centred on the head, above the pet
        let x = clamp(Math.round(tl.x + petW / 2 - w / 2), minX, maxX)
        let y = Math.round(tl.y - h - gap)

        if (y < minY) {
            const below = Math.round(tl.y + petH + gap)
            if (below <= maxY) {
                y = below // no room above — hang it under the pet's feet
            } else {
                // no room above or below — put it beside the pet instead
                const right = Math.round(tl.x + petW + gap)
                const left = Math.round(tl.x - w - gap)
                if (right <= maxX) {
                    x = right
                } else if (left >= minX) {
                    x = left
                }
                y = clamp(Math.round(tl.y + petH / 2 - h / 2), minY, maxY)
            }
        }

        chatDialog.x = x
        chatDialog.y = clamp(y, minY, maxY)
    }

    // ---- lifecycle ----
    Component.onCompleted: {
        healthTimer.start()
        pollHealth()
        // Pick up the password of the systemd unit that runs the backend, if the widget has none.
        if (!Plasmoid.configuration.password) {
            unitSource.connectSource("systemctl --user show opencode-web.service -p Environment --value")
        }
        root.applyWindowMode()
    }

    Component.onDestruction: {
        healthTimer.stop()
        stateTimer.stop()
    }

    onAlwaysOnTopChanged: applyWindowMode()

    onServerAliveChanged: {
        if (serverAlive) {
            stateTimer.start()
        } else {
            stateTimer.stop()
            root.petState = "error"
        }
    }

    // The password arrives asynchronously; sign in as soon as it is known.
    onServerPasswordChanged: openWebUi()

    // ---- animated pet (draggable within the widget) ----
    Item {
        id: compactItem
        anchors.fill: parent

        // pet top-left position inside the widget
        property real petPosX: 0
        property real petPosY: 0
        property bool petInitialized: false
        property string dragDir: ""

        // walking to a clicked spot
        property bool walking: false
        property real walkTargetX: 0
        property real walkTargetY: 0

        Timer {
            id: walkTimer
            interval: 30
            repeat: true
            onTriggered: {
                const dx = compactItem.walkTargetX - compactItem.petPosX
                const dy = compactItem.walkTargetY - compactItem.petPosY
                const dist = Math.sqrt(dx * dx + dy * dy)
                const speed = 3 // px per tick
                if (dist <= speed) {
                    compactItem.petPosX = compactItem.walkTargetX
                    compactItem.petPosY = compactItem.walkTargetY
                    compactItem.stopWalking()
                    return
                }
                compactItem.petPosX += (dx / dist) * speed
                compactItem.petPosY += (dy / dist) * speed
                // Walking animation follows the horizontal direction. Re-assert it
                // when something else took the sprite over (hover, status poll), so
                // the pet keeps walking until it actually arrives.
                const dir = dx > 0 ? "right" : "left"
                const wantAnim = dir === "right" ? "runningRight" : "runningLeft"
                if (dir !== compactItem.dragDir || pet.currentAnim !== wantAnim) {
                    compactItem.dragDir = dir
                    pet.startDragging(dir)
                }
                // keep the popup anchored while the pet walks
                if (chatDialog.visible) {
                    root.positionDialogAtPet()
                }
            }
        }

        // make the pet walk to a widget-local position (centered on the click)
        function walkTo(x, y) {
            const maxX = Math.max(0, compactItem.width - pet.width)
            const maxY = Math.max(0, compactItem.height - pet.height)
            compactItem.walkTargetX = Math.max(0, Math.min(maxX, x - pet.width / 2))
            compactItem.walkTargetY = Math.max(0, Math.min(maxY, y - pet.height / 2))
            compactItem.walking = true
            walkTimer.start()
        }

        function stopWalking() {
            compactItem.walking = false
            walkTimer.stop()
            compactItem.dragDir = ""
            pet.stopDragging()
            // if the pointer ended up over the pet (and we're not mid-press), let it jump
            if (!petArea.pressedActive && petArea.containsMouse &&
                petArea.mouseX >= pet.x && petArea.mouseX <= pet.x + pet.width &&
                petArea.mouseY >= pet.y && petArea.mouseY <= pet.y + pet.height) {
                pet.startHover()
            }
        }

        // center the pet on first layout, clamp it on every resize
        function handleSizeChanged() {
            // Plasma incubates representations asynchronously, so the widget can
            // already be sized while the sprite has not been created yet.
            if (!pet) return
            const maxX = Math.max(0, compactItem.width - pet.width)
            const maxY = Math.max(0, compactItem.height - pet.height)
            if (!compactItem.petInitialized && compactItem.width > 0 && compactItem.height > 0) {
                compactItem.petInitialized = true
                compactItem.petPosX = maxX / 2
                compactItem.petPosY = maxY / 2
            } else {
                compactItem.petPosX = Math.min(compactItem.petPosX, maxX)
                compactItem.petPosY = Math.min(compactItem.petPosY, maxY)
            }
        }

        onWidthChanged: handleSizeChanged()
        onHeightChanged: handleSizeChanged()

        // the sprite may be created after the widget is already sized
        Component.onCompleted: handleSizeChanged()

        PetSprite {
            id: pet
            x: compactItem.petPosX
            y: compactItem.petPosY

            // Never let the sprite grow past the widget: on the desktop the applet
            // keeps its stored geometry, so a pet enlarged with the scroll wheel
            // would be drawn outside the widget bounds (and clipped away).
            size: {
                const want = Plasmoid.configuration.petSize
                const w = compactItem.width
                const h = compactItem.height
                if (w <= 0 || h <= 0) return want
                return Math.max(16, Math.min(want, Math.floor(w), Math.floor(h * 192 / 208)))
            }
            fps: Plasmoid.configuration.petFps
            source: root.petSource
            petState: root.petState

            // resizing the pet (scroll wheel) can push it outside the widget
            onWidthChanged: compactItem.handleSizeChanged()
            onHeightChanged: compactItem.handleSizeChanged()
        }

        // status dot: fixed small red dot, only visible while offline
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            width: 10
            height: 10
            radius: 5
            color: "#e53935"
            border.color: "#ffffff"
            border.width: 1
            opacity: root.serverAlive ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 200 } }
        }

        MouseArea {
            id: petArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor

            property bool pressedActive: false
            property bool moved: false
            property real pressX: 0
            property real pressY: 0
            property real lastX: 0
            property real lastY: 0

            onPressed: (mouse) => {
                pressedActive = true
                moved = false
                pressX = mouse.x
                pressY = mouse.y
                lastX = mouse.x
                lastY = mouse.y
                // stop the hover jump and any walk in progress
                pet.stopHover()
                compactItem.stopWalking()
            }

            onEntered: {
                if (!pressedActive && !compactItem.walking) {
                    pet.startHover()
                }
            }

            onExited: {
                pet.stopHover()
            }

            onWheel: (wheel) => {
                // scroll up = bigger pet, scroll down = smaller pet
                const step = 8
                const delta = wheel.angleDelta.y > 0 ? step : -step
                const newSize = Math.max(32, Math.min(256, Plasmoid.configuration.petSize + delta))
                Plasmoid.configuration.petSize = newSize
            }

            onPositionChanged: (mouse) => {
                if (!pressedActive) return
                const dx = mouse.x - lastX
                const dy = mouse.y - lastY
                if (Math.abs(mouse.x - pressX) > 4 || Math.abs(mouse.y - pressY) > 4) {
                    moved = true
                }
                const maxX = Math.max(0, compactItem.width - pet.width)
                const maxY = Math.max(0, compactItem.height - pet.height)
                compactItem.petPosX = Math.max(0, Math.min(maxX, compactItem.petPosX + dx))
                compactItem.petPosY = Math.max(0, Math.min(maxY, compactItem.petPosY + dy))
                lastX = mouse.x
                lastY = mouse.y

                // keep the popup anchored to the pet's head while dragging
                if (chatDialog.visible) {
                    root.positionDialogAtPet()
                }

                // walking animation follows the horizontal drag direction
                if (Math.abs(dx) > 0.5) {
                    const dir = dx > 0 ? "right" : "left"
                    const wantAnim = dir === "right" ? "runningRight" : "runningLeft"
                    if (dir !== compactItem.dragDir || pet.currentAnim !== wantAnim) {
                        compactItem.dragDir = dir
                        pet.startDragging(dir)
                    }
                }
            }

            onReleased: (mouse) => {
                if (!pressedActive) return
                pressedActive = false
                compactItem.dragDir = ""
                if (moved) {
                    // it was a drag — stop walking
                    pet.stopDragging()
                } else {
                    // plain click — pet or empty area?
                    const onPet = mouse.x >= pet.x && mouse.x <= pet.x + pet.width &&
                                  mouse.y >= pet.y && mouse.y <= pet.y + pet.height
                    if (onPet) {
                        // click on the pet — wave and toggle the opencode popup
                        pet.wave()
                        if (!chatDialog.visible) {
                            root.openWeb()
                        } else if (!root.alwaysOnTop && !chatDialog.active) {
                            // The popup is behind another window: bring it forward.
                            root.raiseWeb()
                        } else {
                            chatDialog.visible = false
                        }
                    } else {
                        // click on empty area — the pet walks there
                        compactItem.walkTo(mouse.x, mouse.y)
                    }
                }
            }

            onCanceled: {
                if (!pressedActive) return
                pressedActive = false
                compactItem.dragDir = ""
                if (moved) {
                    pet.stopDragging()
                }
            }
        }
    }

    // ---- chat popup: custom dialog anchored to the pet's head ----
    PlasmaCore.Dialog {
        id: chatDialog
        location: PlasmaCore.Types.Floating
        // The role and stay-on-top flag are applied by applyWindowMode() in the
        // correct order, both at startup and when the setting changes.
        type: PlasmaCore.Dialog.AppletPopup
        flags: Qt.Dialog
        hideOnWindowDeactivate: false
        backgroundHints: PlasmaCore.Dialog.NoBackground
        visible: false

        onVisibleChanged: {
            if (visible) {
                requestActivate()
                raise()
            }
        }

        mainItem: Item {
            id: chatContent
            // Keep the configured popup size as the content size and add the
            // themed border around it.
            width: root.popupW + 2 * root.popupBorderWidth
            height: root.popupH + 2 * root.popupBorderWidth
            clip: true

            // Draw only the outer half of the Plasma theme frame. The center
            // stays transparent so the web view opacity reveals the desktop.
            Item {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: root.popupBorderWidth
                clip: true

                KSvg.FrameSvgItem {
                    width: chatContent.width
                    height: chatContent.height
                    imagePath: "dialogs/background"
                    prefix: "solid/"
                }
            }

            Item {
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                height: root.popupBorderWidth
                clip: true

                KSvg.FrameSvgItem {
                    y: -(chatContent.height - root.popupBorderWidth)
                    width: chatContent.width
                    height: chatContent.height
                    imagePath: "dialogs/background"
                    prefix: "solid/"
                }
            }

            Item {
                anchors.top: parent.top
                anchors.topMargin: root.popupBorderWidth
                anchors.bottom: parent.bottom
                anchors.bottomMargin: root.popupBorderWidth
                anchors.left: parent.left
                width: root.popupBorderWidth
                clip: true

                KSvg.FrameSvgItem {
                    width: chatContent.width
                    height: chatContent.height
                    imagePath: "dialogs/background"
                    prefix: "solid/"
                }
            }

            Item {
                anchors.top: parent.top
                anchors.topMargin: root.popupBorderWidth
                anchors.bottom: parent.bottom
                anchors.bottomMargin: root.popupBorderWidth
                anchors.right: parent.right
                width: root.popupBorderWidth
                clip: true

                KSvg.FrameSvgItem {
                    x: -(chatContent.width - root.popupBorderWidth)
                    width: chatContent.width
                    height: chatContent.height
                    imagePath: "dialogs/background"
                    prefix: "solid/"
                }
            }

            // slim header: title + status + close
            Rectangle {
                id: headerBar
                anchors.top: parent.top
                anchors.topMargin: root.popupBorderWidth
                anchors.left: parent.left
                anchors.leftMargin: root.popupBorderWidth
                anchors.right: parent.right
                anchors.rightMargin: root.popupBorderWidth
                height: 34
                color: "#181825"
                z: 30

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 6
                    spacing: 8

                    Text {
                        text: "OpenCode"
                        color: "#cdd6f4"
                        font.pixelSize: 13
                        font.bold: true
                        Layout.fillWidth: true
                    }

                    Rectangle {
                        width: 8
                        height: 8
                        radius: 4
                        color: root.serverAlive ? "#a6e3a1" : "#f38ba8"
                        Layout.alignment: Qt.AlignVCenter
                    }

                    Rectangle {
                        width: 24
                        height: 24
                        radius: 4
                        color: "#00000000"
                        Layout.alignment: Qt.AlignVCenter

                        Text {
                            anchors.centerIn: parent
                            text: "✕"
                            color: "#cdd6f4"
                            font.pixelSize: 12
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: chatDialog.visible = false
                            onEntered: parent.color = "#313244"
                            onExited: parent.color = "#00000000"
                        }
                    }
                }
            }

            // opencode web UI
            WebEngineView {
                id: webView
                anchors.top: headerBar.bottom
                anchors.left: parent.left
                anchors.leftMargin: root.popupBorderWidth
                anchors.right: parent.right
                anchors.rightMargin: root.popupBorderWidth
                anchors.bottom: parent.bottom
                anchors.bottomMargin: root.popupBorderWidth
                profile: webProfile
                url: "about:blank"
                visible: root.serverAlive
                opacity: root.webViewOpacity
                backgroundColor: "#1e1e2e"


                onNewWindowRequested: (request) => {
                    Qt.openUrlExternally(request.url)
                }
            }

            // loading overlay
            Rectangle {
                anchors.top: headerBar.bottom
                anchors.left: parent.left
                anchors.leftMargin: root.popupBorderWidth
                anchors.right: parent.right
                anchors.rightMargin: root.popupBorderWidth
                anchors.bottom: parent.bottom
                anchors.bottomMargin: root.popupBorderWidth
                visible: !root.serverAlive
                opacity: root.webViewOpacity
                color: "#1e1e2e"
                z: 10

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 12

                    Text {
                        text: "Conectando ao OpenCode..."
                        color: "#ffffff"
                        font.pixelSize: 16
                        font.bold: true
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Text {
                        text: "Iniciando o servidor..."
                        color: "#a0a0b8"
                        font.pixelSize: 13
                        Layout.alignment: Qt.AlignHCenter
                    }
                    BusyIndicator {
                        running: true
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
            }

            // ---- resize grips ----
            // A Plasma dialog has no window decoration, so the popup carries its
            // own edges: bottom-right corner, right edge and bottom edge.

            MouseArea {
                id: cornerGrip
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                width: 20
                height: 20
                hoverEnabled: true
                cursorShape: Qt.SizeFDiagCursor
                z: 40

                onPressed: (mouse) => root.beginPopupResize(mapToGlobal(mouse.x, mouse.y))
                onPositionChanged: (mouse) => root.updatePopupResize(mapToGlobal(mouse.x, mouse.y), true, true)
                onReleased: root.commitPopupSize()
                onCanceled: root.commitPopupSize()

                // grip indicator: dots in a triangle, counted from the corner
                Repeater {
                    model: [{ c: 0, r: 0 }, { c: 1, r: 0 }, { c: 0, r: 1 },
                            { c: 2, r: 0 }, { c: 1, r: 1 }, { c: 0, r: 2 }]
                    Rectangle {
                        width: 3
                        height: 3
                        radius: 1.5
                        color: cornerGrip.containsMouse || root.popupResizing ? "#cdd6f4" : "#66ffffff"
                        x: cornerGrip.width - 5 - modelData.c * 5
                        y: cornerGrip.height - 5 - modelData.r * 5
                    }
                }
            }

            MouseArea {
                id: rightGrip
                anchors.right: parent.right
                anchors.top: headerBar.bottom
                anchors.bottom: cornerGrip.top
                width: 6
                cursorShape: Qt.SizeHorCursor
                z: 40

                onPressed: (mouse) => root.beginPopupResize(mapToGlobal(mouse.x, mouse.y))
                onPositionChanged: (mouse) => root.updatePopupResize(mapToGlobal(mouse.x, mouse.y), true, false)
                onReleased: root.commitPopupSize()
                onCanceled: root.commitPopupSize()
            }

            MouseArea {
                id: bottomGrip
                anchors.left: parent.left
                anchors.right: cornerGrip.left
                anchors.bottom: parent.bottom
                height: 6
                cursorShape: Qt.SizeVerCursor
                z: 40

                onPressed: (mouse) => root.beginPopupResize(mapToGlobal(mouse.x, mouse.y))
                onPositionChanged: (mouse) => root.updatePopupResize(mapToGlobal(mouse.x, mouse.y), false, true)
                onReleased: root.commitPopupSize()
                onCanceled: root.commitPopupSize()
            }

            // live size readout while dragging an edge
            Rectangle {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.rightMargin: 22
                anchors.bottomMargin: 22
                width: sizeLabel.implicitWidth + 16
                height: sizeLabel.implicitHeight + 8
                radius: 4
                color: "#cc181825"
                visible: root.popupResizing
                z: 50

                Text {
                    id: sizeLabel
                    anchors.centerIn: parent
                    text: root.popupW + " × " + root.popupH
                    color: "#cdd6f4"
                    font.pixelSize: 12
                }
            }
        }
    }
}