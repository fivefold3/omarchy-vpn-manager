import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// WireGuard and OpenVPN in the bar. Profiles are NetworkManager connections;
// all the work goes through the `vpn-nm` script next to this file. Keys stay
// in the profiles, which only root reads, and a password typed here goes to
// that script's stdin and is never kept longer than the call.
Panel {
  id: root
  moduleName: "io.github.fivefold3.vpn-manager"
  ipcTarget: "io.github.fivefold3.vpn-manager"
  manageIpc: false

  readonly property string backend: decodeURIComponent(Qt.resolvedUrl("vpn-nm").toString().replace(/^file:\/\//, ""))
  readonly property int refreshIntervalSec: Math.min(300, Math.max(3, parseInt(setting("refreshIntervalSec", 10), 10) || 10))
  readonly property string importFolder: String(setting("importFolder", "~/Downloads") || "~/Downloads")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string glyph: "󰖂"

  // WireGuard has no connection to set up, so NetworkManager says
  // "connected" straight away, server or no server. A tunnel that has sent
  // for this long without a single byte back has no server answering it.
  readonly property int noReplySec: 10
  property var quietSince: ({})      // uuid → when it was first seen sending with nothing back
  property var noReplyIds: ({})      // uuid → true: quiet for noReplySec or more

  // --- State, from `vpn-nm status` and `profiles` ---
  property bool loaded: false
  property bool installed: true
  property string missing: ""        // packages setup would install
  property bool openvpnInstalled: true
  property string service: ""
  property bool networkUp: false     // NetworkManager has a connection to use
  property bool killSwitch: false    // on: nothing gets out except through a VPN
  // Active VPN connections: { uuid, kind, state, name, ip, iface, sent, recv, secs, hop }.
  // hop is "2/3" for one in a chain, which connects copies of its profiles:
  // uuid and name are then the profile's.
  property var tunnels: []
  // In tree order: each profile is followed by those nested inside it, with
  // via the uuid of the one it's inside and depth how deep that is.
  property var profiles: []
  property var candidates: []        // { path, file, kind, mtime } profile files found in importFolder

  readonly property bool serviceUp: installed && service === "active"
  // The chain that's up, outermost first. All but the last carry the next.
  readonly property var chain: tunnels.filter(function(t) { return t.hop !== "" })
    .sort(function(a, b) { return hopIndex(a) - hopIndex(b) })
  readonly property var connectedList: tunnels.filter(function(t) { return t.state === "connected" })
  // What's connected, as you'd count it: a chain is one connection, its last
  // hop. Its carriers alone carry nothing of yours.
  readonly property var upList: connectedList.filter(function(t) { return !isCarrier(t) })
  readonly property var primary: upList.length > 0 ? upList[0] : connectedList.length > 0 ? connectedList[0]
    : tunnels.length > 0 ? tunnels[0] : null
  readonly property int connectionCount: tunnels.filter(function(t) { return !isCarrier(t) }).length
  readonly property bool connected: serviceUp && upList.length > 0
  // A group's carriers up without its last hop: your traffic isn't in it.
  readonly property bool partly: serviceUp && !connected && connectedList.length > 0
  readonly property bool silent: connected && connectedList.some(noReply)
  readonly property bool transitional: serviceUp && (connectProc.running || autoProc.running
    || tunnels.some(function(t) { return t.state !== "connected" }))
  readonly property bool disconnecting: disconnectProc.running || tunnels.some(function(t) { return t.state === "disconnecting" })

  // --- Action state ---
  property string message: ""
  property bool messageIsError: false
  property string messageUuid: ""     // the profile a connect message is about
  // A connect form that's showing (its profile isn't connecting or up)
  // shows messages about its profile, and general ones.
  readonly property bool messageInForm: expanded !== "" && editing === "" && live(expanded) === null
    && (messageUuid === "" || messageUuid === expanded)
  property string connectingUuid: ""     // while connectProc runs
  property string disconnectingUuid: ""  // while disconnectProc runs ("" for everything)
  property var prompt: null           // { secret, text, context } while NetworkManager waits on an answer
  property bool cancelled: false
  property string afterAction: ""     // what to do once actionProc finishes
  property string pendingSelect: ""   // put the cursor on this profile once it's listed
  property string pendingEdit: ""     // ...and open its settings, saying this
  property string pendingConnect: ""  // an IPC connect waiting on the list to reload
  property var carry: null            // { uuid, password }: typed in the editor, not saved, for the connect form
  property var disconnectQueue: []    // disconnects waiting for the one running
  property bool profilesAgain: false  // a listing was asked for while one ran
  property bool refreshAgain: false   // likewise for a status check
  property real lastStatus: 0         // when the last status check started
  property var heldIds: ({})          // uuid → true: disconnected by you, so not connected automatically
  // An OpenVPN profile set up elsewhere that the kill switch blocks: the
  // next connect of it gives it its own routing table (see the README).
  property string consentUuid: ""
  property var consentRetry: null     // that connect's arguments and typed lines, for the go-ahead
  property bool backendBroken: false  // the status check couldn't run vpn-nm at all
  readonly property string cantRun: "Couldn't run " + backend + ". Reinstall plugin."

  // Connecting automatically: what the panel does itself (a group, or an
  // OpenVPN profile on its own), since NetworkManager can't.
  property real lastAutoConnect: 0
  property int autoFailures: 0        // in a row: each doubles the wait before the next try
  property var autoWarned: ({})       // uuid → true: already told it couldn't connect

  // --- Panel state ---
  // Cursor stops: the list's (see stops), then "Import profile", then (while
  // it's open) the files found.
  property int cursor: 0
  property bool cursorActive: false
  property string expanded: ""        // OpenVPN profile whose connect form is open
  property string editing: ""         // uuid being edited
  property string confirmRemove: ""
  property bool importOpen: false
  property bool typing: false         // a text field owns the keyboard

  readonly property int importRow: stops.length
  readonly property int lastRow: importRow + (importOpen ? candidates.length : 0)

  // Connect form, for whichever OpenVPN profile is expanded.
  property string formUser: ""
  property string formPassword: ""
  property bool formSave: false

  // Profile editor.
  property string editName: ""
  property bool editAuto: false
  property string editVia: ""
  property string editUser: ""
  property string editMode: "ask"     // OpenVPN password: "save" or "ask"
  property string editPassword: ""
  property bool editAll: true

  // Group editor: the group's first profile, and what's being set.
  property string editingGroup: ""
  property string editGroupName: ""
  property bool editGroupAuto: false

  // Dragging a profile onto another nests it inside that one. Where it goes
  // if dropped now: under dropVia ("" for out of its group, its own uuid to
  // stay), or while dropAbove is set, in front of that, a group's first
  // profile, so it's first itself.
  property string dragUuid: ""
  property string dropVia: ""
  property string dropAbove: ""
  property string nestNote: ""        // what to say once a nest is saved

  // Import box.
  property string importPath: ""

  readonly property string barTooltip: backendBroken ? "VPN: couldn't run vpn-nm" : !installed ? "VPN: " + missing + " missing"
    : !serviceUp ? "NetworkManager isn't running"
    : silent ? "VPN: no reply from server · " + upNames()
    : connected ? "VPN connected · " + upNames() + (primary && primary.ip ? " · " + primary.ip : "")
    : transitional ? (disconnecting ? "VPN disconnecting…" : "VPN connecting…")
    : partly ? "VPN partly connected: traffic not routed via VPN · " + partNames()
    : killSwitch ? "VPN off · internet blocked" : "VPN disconnected"

  readonly property string heroMeta: backendBroken ? "Couldn't run vpn-nm" : !loaded ? "Checking…"
    : !installed ? "Needs setup"
    : !serviceUp ? "NetworkManager is off"
    : silent ? "No reply"
    : connected ? "Connected · " + upNames()
    : transitional ? (disconnecting ? "Disconnecting…" : "Connecting…")
    : partly ? "Partly connected · " + partNames()
    : killSwitch ? "Internet blocked"
    : "Disconnected"

  function upNames() {
    return upList.map(function(t) {
      var head = t.hop !== "" && chain.length > 0 ? profile(chain[0].uuid) : null
      if (head && head.group !== "") return head.group
      return t.name + (routeTo(t) !== "" ? " via " + routeTo(t) : "")
    }).join(", ")
  }

  // The hops up in a group whose last hop isn't.
  function partNames() { return connectedList.map(function(t) { return t.name }).join(" › ") }

  function kindLabel(kind) { return kind === "ovpn" ? "OpenVPN" : "WireGuard" }

  function typeLabel(auth) {
    return auth === "password" ? "Password"
      : auth === "password-tls" ? "Password + certificate"
      : auth === "static-key" ? "Static key" : "Certificate"
  }

  function needsPassword(p) { return !!p && p.kind === "ovpn" && (p.auth === "password" || p.auth === "password-tls") }

  // Connects without asking anything first: WireGuard, or an OpenVPN profile
  // with its password saved, or none used. A key's password, or a one-time
  // code, is asked for while it connects.
  function readyToConnect(p) {
    return !!p && (!needsPassword(p) || (p.username !== "" && p.pwMode === "save" && p.hasPassword))
  }

  // The profile nested in this one, if any: each carries one at most.
  function childOf(uuid) {
    for (var i = 0; i < profiles.length; i++) if (profiles[i].via === uuid) return profiles[i]
    return null
  }

  // A profile's group, outermost first: those it's nested inside, itself,
  // and those nested in it. Just itself when it's in none.
  function groupOf(uuid) {
    var list = []
    var p = profile(uuid)
    for (var n = 0; p && n < profiles.length; n++) { list.unshift(p); p = profile(p.via) }
    var c = childOf(uuid)
    for (n = 0; c && n < profiles.length; n++) { list.push(c); c = childOf(c.uuid) }
    return list
  }

  function inGroup(uuid) { return groupOf(uuid).length > 1 }

  // The list as it's drawn: a profile on its own, or a group in a box.
  // { members: [{ p, index: its place in profiles }] }
  readonly property var blocks: {
    var out = []
    for (var i = 0; i < profiles.length; i++) {
      var p = profiles[i]
      var last = out.length > 0 ? out[out.length - 1] : null
      if (p.via !== "" && last && last.members[last.members.length - 1].p.uuid === p.via)
        last.members.push({ p: p, index: i })
      else
        out.push({ members: [{ p: p, index: i }] })
    }
    return out
  }

  // The list's cursor stops, in order: a group's name, then each of its
  // profiles, and a profile on its own.
  // { uuid, header: on a group's name (uuid is its first profile's), block }
  readonly property var stops: {
    var out = []
    for (var b = 0; b < blocks.length; b++) {
      var members = blocks[b].members
      if (members.length > 1) out.push({ uuid: members[0].p.uuid, header: true, block: b })
      for (var k = 0; k < members.length; k++) out.push({ uuid: members[k].p.uuid, header: false, block: b })
    }
    return out
  }

  // The stop the cursor is on, while it's on the list; null otherwise.
  function cursorStop() { return cursorActive && cursor < importRow ? stops[cursor] : null }

  // The profile the cursor is on: none on a group's name.
  function cursorProfile() {
    var s = cursorStop()
    return s && !s.header ? profile(s.uuid) : null
  }

  function cursorOn(uuid, header) {
    var s = cursorStop()
    return !!s && s.uuid === uuid && s.header === header
  }

  function stopOf(uuid, header) {
    for (var i = 0; i < stops.length; i++) if (stops[i].uuid === uuid && stops[i].header === header) return i
    return -1
  }

  // Rows moving under a pointer that's still (the list changing, the
  // keyboard scrolling it) don't take the cursor: only moving it does.
  PointerMoveGate {
    id: pointerGate
    referenceItem: keyCatcher
  }

  // The pointer moved onto a profile, or a group's name.
  function pointAt(uuid, header, item, mouse) {
    if (dragUuid !== "" || !pointerGate.moved(item, mouse)) return
    var i = stopOf(uuid, header)
    if (i < 0) return
    cursorActive = true
    cursor = i
  }

  // The row drawn for profile i.
  function rowItem(i) {
    for (var b = 0; b < blockRepeater.count; b++) {
      var item = blockRepeater.itemAt(b)
      var r = item ? item.rowFor(i) : null
      if (r) return r
    }
    return null
  }

  // Its name, or else its route: "aus › zch › usa".
  function groupName(uuid) {
    var g = groupOf(uuid)
    if (g.length > 0 && g[0].group !== "") return g[0].group
    return g.map(function(p) { return p.name }).join(" › ")
  }

  function hopIndex(t) { return parseInt(t.hop, 10) || 0 }
  function isCarrier(t) { return !!t && t.hop !== "" && hopIndex(t) < (parseInt(t.hop.split("/")[1], 10) || 0) }

  // The hops before one in the chain, "aus › zch"; "" for one not in a chain.
  function routeTo(t) {
    if (!t || t.hop === "") return ""
    return chain.filter(function(c) { return hopIndex(c) < hopIndex(t) }).map(function(c) { return c.name }).join(" › ")
  }

  // The hop a carrier carries.
  function carried(t) {
    if (!isCarrier(t)) return null
    for (var i = 0; i < chain.length; i++) if (hopIndex(chain[i]) === hopIndex(t) + 1) return chain[i]
    return null
  }

  // A profile and those it's nested inside, outermost first: "aus › zch".
  function viaNames(via) {
    var names = []
    var p = profile(via)
    for (var n = 0; p && n < profiles.length; n++) {
      names.unshift(p.name)
      p = profile(p.via)
    }
    return names.join(" › ")
  }

  function noReply(t) { return !!(t && noReplyIds[t.uuid]) }

  function profile(uuid) {
    for (var i = 0; i < profiles.length; i++) if (profiles[i].uuid === uuid) return profiles[i]
    return null
  }

  function profileByName(name) {
    for (var i = 0; i < profiles.length; i++) if (profiles[i].name === name || profiles[i].uuid === name) return profiles[i]
    // A group's name: its first profile, which connects all of it.
    for (i = 0; i < profiles.length; i++) if (profiles[i].group !== "" && profiles[i].group === name) return profiles[i]
    return null
  }

  function live(uuid) {
    for (var i = 0; i < tunnels.length; i++) if (tunnels[i].uuid === uuid) return tunnels[i]
    return null
  }

  function say(text, isError) {
    message = text || ""
    messageIsError = !!isError
    messageUuid = ""
  }

  // A message about one profile's connection, named so it can't be read as
  // being about another one that's connected.
  function sayFor(uuid, text, isError) {
    var p = profile(uuid)
    say(p && text ? p.name + ": " + text : text, isError)
    messageUuid = uuid
  }

  function formatBytes(n) {
    var v = Number(n) || 0
    var units = ["B", "KB", "MB", "GB", "TB"]
    var i = 0
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
    return (i === 0 ? v : v.toFixed(1)) + " " + units[i]
  }

  function formatDuration(s) {
    var n = parseInt(s, 10)
    if (isNaN(n)) return "—"
    var h = Math.floor(n / 3600), m = Math.floor(n % 3600 / 60), sec = n % 60
    var pad = function(x) { return x < 10 ? "0" + x : String(x) }
    return h > 0 ? h + "h " + pad(m) + "m" : m > 0 ? m + "m " + pad(sec) + "s" : sec + "s"
  }

  function formatAge(mtime) {
    var s = Date.now() / 1000 - mtime
    if (s < 3600) return "just now"
    if (s < 86400) return Math.floor(s / 3600) + " h ago"
    if (s < 86400 * 60) return Math.floor(s / 86400) + " d ago"
    return Qt.formatDate(new Date(mtime * 1000), "d MMM yyyy")
  }

  // The body is read as markup: a profile's name mustn't become a link.
  function notify(title, body) {
    var plain = String(body || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    Quickshell.execDetached(["omarchy-notification-send", "--app-name", "VPN", "-g", glyph, "-u", "normal", title, plain])
  }

  // The bar has a copy of this widget on each monitor. Only the first acts on
  // its own (connecting automatically, and saying when that fails), so the
  // others don't repeat it.
  function isLeader() { return leader() === root }

  // All the copies, this one included.
  function copies() {
    if (!bar || typeof bar.moduleWidgets !== "function") return [root]
    var items = bar.moduleWidgets(moduleName)
    return items.length > 0 ? items : [root]
  }

  function leader() {
    var items = copies()
    return typeof items[0].refresh === "function" ? items[0] : root
  }

  // --- Backend calls ---

  // The first copy checks for all of them, and tells each what it found.
  // NetworkManager answers status while other calls run, so this never
  // waits. A check already running may predate the change that asks for
  // this one. At most one a second.
  function refresh() {
    if (!isLeader()) { leader().refresh(); return }
    if (statusProc.running) { refreshAgain = true; return }
    var wait = lastStatus + 1000 - Date.now()
    if (wait > 0) { statusFloor.interval = wait; statusFloor.restart(); return }
    lastStatus = Date.now()
    statusProc.busy = true
    statusProc.running = true
  }

  // After a change, all the copies hear straight away instead of on the
  // next poll.
  function refreshAll() { refresh() }

  // A listing already running may have started before the change that asks
  // for this one, so run again once it's done.
  function loadProfiles() {
    if (!serviceUp) return
    if (profilesProc.running) profilesAgain = true
    else profilesProc.running = true
  }

  // After a change to the profiles: the other copies' lists, the first's
  // above all (it connects automatically), are out of date too.
  function loadProfilesAll() {
    var items = copies()
    for (var i = 0; i < items.length; i++)
      if (typeof items[i].loadProfiles === "function") items[i].loadProfiles()
  }

  // A connect of uuid's group under way here stops (any, without a uuid).
  // Whether it cancelled one: that connect disconnects its own profile once
  // it has stopped (see connectProc), so the caller needn't.
  function cancelFor(uuid) {
    if (!connectProc.running || (uuid && !groupOf(uuid).some(function(q) { return q.uuid === connectingUuid }))) return false
    cancelConnect()
    return true
  }

  function loadCandidates() {
    if (!candidatesProc.running) candidatesProc.running = true
  }

  // One change at a time. secret, when given, is written to the script's
  // stdin as its first line.
  function run(args, then, secret) {
    if (actionProc.running) { say("Wait for last change to finish.", true); return false }
    afterAction = then || ""
    // Notes for an earlier change's profile don't carry over to this one's.
    pendingEdit = ""
    pendingOpenVpn = ""
    say("", false)
    actionProc.secret = secret || ""
    actionProc.busy = true
    actionProc.command = [backend].concat(args)
    actionProc.running = true
    return true
  }

  // Why a connect can't start now, or "".
  function connectBlocked() {
    if (connectProc.running) {
      var c = profile(connectingUuid)
      return "Wait for " + (c ? c.name : "last profile") + " to finish connecting."
    }
    return ""
  }

  // Connecting runs on its own: it can take a while (an OpenVPN server, a
  // question to answer, a group connecting hop by hop), and changes and
  // disconnects needn't wait for it.
  function startConnect(uuid, args, secret) {
    if (connectBlocked() !== "") { say(connectBlocked(), true); return }
    // Kept for the go-ahead, should this connect be asked about (exit 3).
    consentRetry = { args: args || [], secret: secret || "" }
    // Asked about last time: this connect is the go-ahead.
    if (consentUuid === uuid) args = (args || []).concat(["--own-table"])
    consentUuid = ""
    connectProc.secret = secret || ""
    cancelled = false
    connectingUuid = uuid
    prompt = null
    say("", false)
    connectProc.command = [backend, "connect", uuid].concat(args || [])
    connectProc.running = true
  }

  // From the connect form: the username and password typed, and whether to
  // keep the password.
  function connectWithForm(uuid) {
    var p = profile(uuid)
    if (!p) return
    // Asked about last time: the same connect again, with the go-ahead.
    if (consentUuid === uuid && consentRetry) { startConnect(uuid, consentRetry.args, consentRetry.secret); focusList(); return }
    // Kept until the connect can start, so nothing typed is lost.
    if (connectBlocked() !== "") { say(connectBlocked(), true); return }
    var args = []
    var lines = []                      // on stdin, as the backend reads them
    if (needsPassword(p)) {
      if (p.username === "") {
        if (formUser.trim() === "") { say("Enter username.", true); return }
        if (/[\t\n]/.test(formUser)) { say("Username can't contain tabs or line breaks.", true); return }
        args.push("--user-stdin")
        lines.push(formUser.trim())
      }
      var stored = p.pwMode === "save" && p.hasPassword
      if (formPassword === "" && !(stored && formSave)) { say("Enter password.", true); return }
      if (formSave !== (p.pwMode === "save") || (formSave && formPassword !== "")) args.push(formSave ? "--save" : "--ask")
      if (formPassword !== "") { args.push("--password-stdin"); lines.push(formPassword) }
    }
    formPassword = ""
    startConnect(uuid, args, lines.join("\n"))
    focusList()
  }

  function showPrompt(secret, text, context) {
    // Open first, so the panel's own focus handling runs before the answer
    // field claims the keyboard; the timer covers the panel mapping late.
    if (!opened) open()
    prompt = { secret: secret, text: text, context: context }
    promptFocus.restart()
  }

  function answerPrompt(text) {
    if (!prompt || !connectProc.running) return
    connectProc.write(text + "\n")
    prompt = null
    focusList()
  }

  function cancelConnect() {
    if (!connectProc.running) return
    cancelled = true
    prompt = null
    connectProc.running = false
  }

  // A question gone (answered, cancelled, or the connect over): its field
  // is emptied, and the keyboard goes back to the list, since Qt leaves it
  // on hidden fields.
  onPromptChanged: if (prompt === null) {
    promptField.text = ""
    if (promptField.activeFocus) focusList()
  }

  // Without a uuid: every VPN, and a connect under way stops. From IPC
  // (force), the list may be a poll out of date, so the backend decides
  // what's up.
  function disconnect(uuid, force) {
    var items = copies()
    var cancelledOne = false
    for (var i = 0; i < items.length; i++)
      if (typeof items[i].cancelFor === "function" && items[i].cancelFor(uuid)) cancelledOne = true
    if (!uuid && tunnels.length === 0 && !force) return
    // A cancelled connect of this profile's group disconnects it itself
    // once it has stopped; a second disconnect now would race it.
    if (uuid && cancelledOne) return
    runDisconnect(uuid ? ["disconnect", uuid] : ["disconnect"])
  }

  // Disconnects run on their own, so they never wait for a connect (which
  // can sit on a question for a minute) or a profile change.
  function runDisconnect(args) {
    if (disconnectProc.running) { disconnectQueue = disconnectQueue.concat([args]); return }
    disconnectingUuid = args.length > 1 ? args[1] : ""
    disconnectProc.busy = true
    disconnectProc.command = [backend].concat(args)
    disconnectProc.running = true
  }

  // One of the profile's group that's connected, to disconnect the group
  // by; "" when none is.
  function upIn(uuid) {
    var up = groupOf(uuid).filter(function(p) { return live(p.uuid) !== null })
    return up.length > 0 ? up[0].uuid : ""
  }

  // Clicking a profile. A group goes on and off as one, whichever of its
  // profiles is clicked. One that's connecting stops. An OpenVPN profile
  // that needs a password typed opens its connect form; the rest connect
  // straight away.
  function toggleProfile(uuid) {
    var group = groupOf(uuid)
    if (connectProc.running && group.some(function(q) { return q.uuid === connectingUuid })) { disconnect(uuid); return }
    var up = upIn(uuid)
    if (up !== "") { disconnect(up); return }
    var p = profile(uuid)
    if (!p) return
    if (consentUuid === uuid && consentRetry) { keyCatcher.forceActiveFocus(); startConnect(uuid, consentRetry.args, consentRetry.secret); return }
    if (group.length === 1 && (expanded === uuid || !readyToConnect(p))) { expand(uuid); return }
    keyCatcher.forceActiveFocus()
    expanded = ""
    startConnect(uuid, [], "")
  }

  // What connects automatically, other than uuid (a profile, or a group
  // by its first profile): its name, or "". One at most does.
  function autoElsewhere(uuid) {
    for (var i = 0; i < profiles.length; i++) {
      var p = profiles[i]
      if (p.uuid === uuid) continue
      if (p.autoConnect) return p.name
      if (p.via === "" && p.groupAuto && childOf(p.uuid) !== null) return groupName(p.uuid)
    }
    return ""
  }

  function autoNote(uuid) {
    var other = autoElsewhere(uuid)
    return other !== "" ? " Only one profile or group can: " + other + " stops." : ""
  }

  // For IPC: takes a profile name or uuid. The list only reloads while the
  // panel is open, and profiles can change behind its back (nmcli, another
  // import), so reload it first. Right after the shell starts, the first
  // status check has to finish before that.
  function connectByName(name, reloaded) {
    if (!reloaded && (!loaded || serviceUp)) {
      pendingConnect = name
      if (serviceUp) loadProfiles()
      return
    }
    var p = profileByName(name)
    if (p && (upIn(p.uuid) !== "" || connectingUuid === p.uuid)) return  // up, or on its way
    if (p && (inGroup(p.uuid) || readyToConnect(p)) && connectBlocked() === "") { startConnect(p.uuid, [], ""); return }
    open()
    if (p && !inGroup(p.uuid) && !readyToConnect(p)) { expand(p.uuid); return }
    say(!installed ? "Missing packages: " + missing + ". Run setup to install."
      : !serviceUp ? "NetworkManager isn't running."
      : p ? connectBlocked() : "No profile called " + name + ".", true)
  }

  // What the panel connects automatically, a group or an OpenVPN profile on
  // its own, when nothing's connected: the backend leaves one you
  // disconnected alone, and lets one panel at a time try. A try that fails
  // waits twice as long as the last before the next, up to ten minutes.
  function autoOwner() {
    for (var i = 0; i < profiles.length; i++) {
      var p = profiles[i]
      if (p.via !== "") continue
      if (childOf(p.uuid) !== null) { if (p.groupAuto) return p }
      else if (p.kind === "ovpn" && p.autoConnect) return p
    }
    return null
  }

  function autoConnect() {
    if (!isLeader() || !serviceUp || !networkUp || tunnels.length > 0) return
    if (connectProc.running || actionProc.running || disconnectProc.running || autoProc.running) return
    if (Date.now() - lastAutoConnect < Math.min(600000, 30000 * Math.pow(2, autoFailures))) return
    var p = autoOwner()
    if (!p || heldIds[p.uuid]) return  // you disconnected it: the backend would leave it anyway
    lastAutoConnect = Date.now()
    autoProc.uuid = p.uuid
    autoProc.command = [backend, "connect", "--auto", p.uuid]
    autoProc.running = true
  }

  function openGroupEditor(uuid) {
    var head = groupOf(uuid)[0]
    keyCatcher.forceActiveFocus()
    editing = ""
    expanded = ""
    confirmRemove = ""
    if (!head || editingGroup === head.uuid) { closeGroupEditor(); return }
    editingGroup = head.uuid
    editGroupName = head.group
    editGroupAuto = head.groupAuto
    say("", false)
  }

  function closeGroupEditor() {
    editingGroup = ""
    say("", false)
    focusList()
  }

  function saveGroupEditor() {
    if (editingGroup !== "") run(["group", editingGroup, editGroupName.trim(), editGroupAuto ? "1" : "0"], "saved")
  }

  function setKillSwitch(on) {
    run(["killswitch", on ? "on" : "off"], on ? "killswitch-on" : "killswitch-off")
  }

  function runSetup() {
    close()
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", Util.shellQuote(backend) + " setup"])
  }

  function importFiles(paths) {
    var list = paths.filter(function(p) { return p !== "" })
    if (list.length === 0) { say("Enter a path to a WireGuard .conf or OpenVPN .ovpn file.", true); return }
    run(["import"].concat(list), "imported")
  }

  // The backend reads the clipboard itself, so the config (keys and all)
  // never passes through the panel.
  function pasteConfig() {
    run(["paste"], "pasted")
  }

  // The file chooser is an ordinary window, so get the panel out of its way
  // and come back once a file is picked.
  function browse() {
    if (browseProc.running) return
    close()
    browseProc.command = [backend, "browse", importFolder]
    browseProc.running = true
  }

  // What the first copy's status check found.
  function applyStatus(text) {
    var v = {}
    var list = []
    var held = {}
    var lines = text.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var f = lines[i].split("\t")
      if (f[0] === "vpn" && f.length >= 10) {
        list.push({ uuid: f[1], kind: f[2], state: f[3], name: f[4], ip: f[5], iface: f[6],
                    sent: f[7], recv: f[8], secs: f[9], hop: f[10] || "" })
      } else if (f[0] === "held" && f.length === 2) {
        held[f[1]] = true
      } else if (f.length === 2) {
        v[f[0]] = f[1]
      }
    }
    if (v.installed === undefined) return
    backendBroken = false
    installed = v.installed === "1"
    missing = v.missing || ""
    openvpnInstalled = v.openvpn !== "0"
    service = v.service || ""
    killSwitch = v.killswitch === "1"
    heldIds = held
    // "connected", or "connected (site only)": a captive portal may still
    // want logging in to, but a VPN can try.
    networkUp = serviceUp && /^connected($| \(site)/.test(v.network || "")
    var now = Date.now()
    var quiet = {}
    var silentIds = {}
    for (var j = 0; j < list.length; j++) {
      var t = list[j]
      if (t.kind !== "wg" || t.state !== "connected" || Number(t.sent) === 0 || Number(t.recv) > 0) continue
      quiet[t.uuid] = quietSince[t.uuid] || now
      if (now - quiet[t.uuid] >= noReplySec * 1000) silentIds[t.uuid] = true
    }
    quietSince = quiet
    noReplyIds = silentIds
    tunnels = list
    loaded = true
    autoConnect()
    // An IPC connect that waited for this, with nothing to connect through.
    if (pendingConnect !== "" && !serviceUp) {
      var name = pendingConnect
      pendingConnect = ""
      connectByName(name, true)
    }
  }

  // --- Panel actions ---

  // An OpenVPN profile's connect form, for its username and password.
  function expand(uuid) {
    var p = profile(uuid)
    // Take focus back before the old form hides: Qt leaves it on hidden fields.
    keyCatcher.forceActiveFocus()
    editing = ""
    editingGroup = ""
    confirmRemove = ""
    if (!p || expanded === uuid) { expanded = ""; return }
    expanded = uuid
    formUser = ""
    formPassword = ""
    formSave = p.pwMode === "save"
    say("", false)
    Qt.callLater(focusForm)
  }

  function openEditor(uuid) {
    var p = profile(uuid)
    keyCatcher.forceActiveFocus()
    confirmRemove = ""
    expanded = ""
    if (!p || editing === uuid) { closeEditor(); return }
    editing = p.uuid
    editName = p.name
    editAuto = p.autoConnect
    editVia = p.via
    editUser = p.username
    editMode = p.pwMode === "save" ? "save" : "ask"
    editPassword = ""
    editAll = p.allTraffic
    editingGroup = ""
    say("", false)
  }

  function closeEditor() {
    editing = ""
    editPassword = ""
    say("", false)
    focusList()
  }

  // Connecting automatically needs a saved password, since nobody's there
  // to type it, so the two switches move together: turning on Connect
  // automatically saves the password, and turning off Save password stops
  // connecting automatically.
  function setEditAuto(on) {
    editAuto = on
    if (on && needsPassword(profile(editing))) editMode = "save"
  }

  function setEditSave(on) {
    editMode = on ? "save" : "ask"
    if (!on && needsPassword(profile(editing))) editAuto = false
  }

  function saveEditor() {
    var p = profile(editing)
    if (!p) return
    var name = editName.trim()
    if (name === "") { say("Enter a profile name.", true); return }
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].uuid !== p.uuid && profiles[i].name === name) { say("Profile name " + name + " is already in use.", true); return }
    }
    // A profile in a group connects with it only. The group has its own
    // Connect automatically, in its editor.
    var grouped = editVia !== "" || childOf(p.uuid) !== null
    var auto = editAuto && !grouped
    if (needsPassword(p) && editUser.trim() === "") { say("Enter username.", true); return }
    if (auto && needsPassword(p) && !p.hasPassword && editPassword === "") {
      say("Enter password to save and enable automatic connection.", true)
      return
    }
    var args = ["save", p.uuid, name, auto ? "1" : "0"]
    if (editVia !== p.via) args.push("--via", editVia)
    var lines = []                      // on stdin: the username, then the password
    if (p.kind === "ovpn") {
      if (needsPassword(p)) {
        if (/[\t\n]/.test(editUser)) { say("Username can't contain tabs or line breaks.", true); return }
        args.push("--user-stdin", "--password", editMode)
        lines.push(editUser.trim())
        if (editMode === "save" && editPassword !== "") { args.push("--password-stdin"); lines.push(editPassword) }
      }
      args.push("--all-traffic", editAll ? "1" : "0")
    }
    var secret = lines.join("\n")
    // Not saved, but typed all the same: once saved, the connect form opens
    // with it, ready to connect.
    var unsaved = needsPassword(p) && editMode !== "save" ? editPassword : ""
    if (run(args, "saved", secret)) carry = unsaved !== "" ? { uuid: p.uuid, password: unsaved } : null
  }

  // The profiles the editor's profile can go inside: any other, since it
  // moves as in a list.
  function viaOptions(uuid) {
    var list = [{ value: "", label: "Directly" }]
    for (var i = 0; i < profiles.length; i++) {
      var p = profiles[i]
      if (p.uuid !== uuid) list.push({ value: p.uuid, label: viaNames(p.uuid) })
    }
    return list
  }

  // Moves one profile, as in a list: just under another (via), taking over
  // what that one carried, or with via "", out of its group. What it
  // carried closes up behind it.
  // A form open on it goes, typed password and all: it may not connect on
  // its own any more.
  function clearForms() {
    keyCatcher.forceActiveFocus()
    expanded = ""
    formPassword = ""
    carry = null
  }

  function nestProfile(uuid, via) {
    var p = profile(uuid)
    if (!p || !movesTo(p, via)) return
    if (moveBusy(uuid, via) !== "") { say("Disconnect " + moveBusy(uuid, via) + " before moving.", true); return }
    clearForms()
    nestNote = p.name + (via !== "" ? " now connects through " + viaNames(via) + "." : " now connects independently.")
    if (run(via !== "" ? ["move", uuid, via] : ["move", uuid], "nested")) pendingSelect = uuid
  }

  // Moves one profile in front of another, as in a list: just under the one
  // before it, or in front of a group's first profile, first itself, and
  // carrying the rest. What it carried closes up behind it.
  function moveAbove(uuid, other) {
    var p = profile(uuid)
    var o = profile(other)
    if (!p || !o || uuid === other || o.via === uuid) return
    if (moveBusy(uuid, other) !== "") { say("Disconnect " + moveBusy(uuid, other) + " before moving.", true); return }
    clearForms()
    nestNote = p.name + (o.via !== "" ? " now connects through " + viaNames(o.via) : " now goes first") + ", carrying " + o.name + "."
    if (run(["move", uuid, "--above", other], "nested")) pendingSelect = uuid
  }

  // Whether moving p under via ("" for out of its group) would change
  // anything. Under itself, or the one it's already under, it stays. Out
  // of a group: anything nested, or a group's first profile, which leaves
  // the rest behind. A profile on its own is out already.
  function movesTo(p, via) {
    if (via === p.uuid) return false
    return via !== "" ? via !== p.via : p.via !== "" || childOf(p.uuid) !== null
  }

  // What a move would change that's connected or connecting, by name (a
  // group's, for one in a group), or "". The profile's own group changes,
  // and the one it goes into. A move doesn't touch tunnels that are up, so
  // it waits until they're down: otherwise the list would show a group
  // that isn't what's running.
  function moveBusy(uuid, other) {
    var groups = [groupOf(uuid)].concat(other && other !== uuid ? [groupOf(other)] : [])
    for (var g = 0; g < groups.length; g++)
      for (var i = 0; i < groups[g].length; i++) {
        var q = groups[g][i]
        if (live(q.uuid) || (connectProc.running && q.uuid === connectingUuid) || (autoProc.running && q.uuid === autoProc.uuid))
          return groups[g].length > 1 ? groupName(q.uuid) : q.name
      }
    return ""
  }

  // ← and → on a profile: up one place in its group (from second place, to
  // first; from first, out of the group), or in under the profile above it.
  function nestStep(dx) {
    var p = cursorProfile()
    if (!p) return
    if (dx > 0) {
      var above = profiles[profiles.indexOf(p) - 1]
      if (above && above.uuid !== p.via) nestProfile(p.uuid, above.uuid)
    } else if (p.via !== "") {
      moveAbove(p.uuid, p.via)
    } else {
      nestProfile(p.uuid, "")
    }
  }

  // Dragging: the profile under the pointer (at x, y in item) is the one the
  // dragged one goes in under; over the dragged one itself, it stays where
  // it is. Over a group's name, it goes first in the group; anywhere else
  // in a group's box, last. Over no profile, it goes out of its group.
  function dragOver(item, x, y) {
    var over = null
    var first = null
    for (var i = 0; i < profiles.length && !over; i++) {
      var r = rowItem(i)
      if (!r) continue
      var pt = item.mapToItem(r, x, y)
      if (pt.x >= 0 && pt.x < r.width && pt.y >= 0 && pt.y < r.height) over = profiles[i]
    }
    for (var b = 0; b < blockRepeater.count && !over && !first; b++) {
      var box = blockRepeater.itemAt(b)
      var members = blocks[b].members
      if (!box || members.length < 2) continue
      var bp = item.mapToItem(box, x, y)
      if (bp.x < 0 || bp.x >= box.width || bp.y < 0 || bp.y >= box.height) continue
      if (bp.y < box.headerItem.mapToItem(box, 0, box.headerItem.height).y) first = members[0].p
      else over = members[members.length - 1].p
    }
    dropAbove = first ? first.uuid : ""
    // Over itself, its own uuid: it stays. That can't be "", which for a
    // group's first profile would mean out of the group.
    dropVia = over ? over.uuid : first ? dragUuid : ""
  }

  // Whether dropping now would move the dragged profile.
  readonly property bool dropMoves: {
    var p = profile(dragUuid)
    return !!p && (dropAbove !== "" ? dropAbove !== p.uuid : movesTo(p, dropVia))
  }

  // What's connected that stops the drop, or "".
  readonly property string dropBusy: dropMoves ? moveBusy(dragUuid, dropAbove !== "" ? dropAbove : dropVia) : ""

  // What lights up while dragging: the profile it would go in under, the
  // first profile it would go in front of, or the space to take it out.
  // Nothing, while something connected stops the drop.
  readonly property bool dropOk: dropMoves && dropBusy === ""
  function dropsUnder(uuid) { return dropOk && dropAbove === "" && dropVia === uuid }
  function dropsAbove(uuid) { return dropOk && dropAbove === uuid }
  readonly property bool dropsOut: dropOk && dropAbove === "" && dropVia === ""

  // Whether the profile being dragged is in a group, and so can be taken out.
  readonly property bool dragCanLeave: {
    var p = profile(dragUuid)
    return !!p && (p.via !== "" || childOf(p.uuid) !== null)
  }

  function drop() {
    var uuid = dragUuid
    dragUuid = ""
    // Each does nothing when it stays.
    if (dropAbove !== "") moveAbove(uuid, dropAbove)
    else nestProfile(uuid, dropVia)
  }

  // The profile's config, as a wg-quick or .ovpn file in your editor. That
  // runs in a terminal, which says how it went; the list reloads when the
  // panel next opens.
  function editConfig(uuid) {
    if (!profile(uuid)) return
    close()
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", Util.shellQuote(backend) + " edit " + uuid])
  }

  function removeProfile(uuid) {
    if (confirmRemove !== uuid) { confirmRemove = uuid; confirmTimer.restart(); return }
    confirmRemove = ""
    if (editing === uuid) editing = ""
    if (expanded === uuid) expanded = ""
    run(["remove", uuid], "profiles")
  }

  // From the keyboard (typed), the path field gets the keys; Down goes
  // back to the list.
  function toggleImport(typed) {
    keyCatcher.forceActiveFocus()
    editing = ""
    expanded = ""
    editingGroup = ""
    importOpen = !importOpen
    if (importOpen) {
      say("", false)
      loadCandidates()
      if (typed) Qt.callLater(function() { importBox.focusPath() })
    } else cursor = Math.min(cursor, lastRow)
  }

  function focusList() {
    typing = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Nothing (left) has the keyboard: the list takes it.
  function regainFocus() {
    var f = keyCatcher.Window.activeFocusItem
    if (!f || !f.visible) focusList()
  }

  function moveCursor(dy) {
    pointerGate.reset()
    cursorActive = true
    cursor = Math.max(0, Math.min(lastRow, cursor + dy))
    scrollCursorIntoView()
  }

  // The row the keyboard cursor is on, as an item in the list.
  function cursorItem() {
    if (cursor < importRow) {
      var s = stops[cursor]
      var box = s ? blockRepeater.itemAt(s.block) : null
      return !box ? null : s.header ? box.headerItem : box.rowFor(profiles.indexOf(profile(s.uuid)))
    }
    if (cursor === importRow) return importRowItem
    return importBox.rowAt(cursor - importRow - 1)
  }

  function scrollCursorIntoView() {
    Qt.callLater(function() {
      var item = cursorItem()
      if (!item || !item.visible) return
      var margin = Style.space(6)
      var top = item.mapToItem(flick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, flick.contentHeight - flick.height)
      if (top < flick.contentY + margin) flick.contentY = Math.max(0, top - margin)
      else if (bottom > flick.contentY + flick.height - margin) flick.contentY = Math.min(maxY, bottom + margin - flick.height)
    })
  }

  function activateCursor() {
    if (cursor === importRow) { toggleImport(); return }
    if (cursor > importRow) {
      var c = candidates[cursor - importRow - 1]
      if (c) importFiles([c.path])
      return
    }
    var s = stops[cursor]
    if (!s) return
    if (!s.header && expanded === s.uuid && !live(s.uuid) && connectingUuid !== s.uuid) connectWithForm(s.uuid)
    else toggleProfile(s.uuid)
  }

  // --- Lifecycle ---

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Clicking another window closes the panel, so what's been typed survives
  // that for a while: go and copy a username or password, come back, and the
  // form is as it was.
  onOpenedChanged: {
    if (opened) {
      // A question from a connect another copy started is answered there.
      var items = copies()
      for (var i = 0; i < items.length; i++) {
        if (items[i] !== root && items[i].prompt) { close(); items[i].open(); return }
      }
      forgetTimer.stop()
      pointerGate.reset()
      cursorActive = false
      flick.contentY = 0
      refresh()
      loadProfiles()
      if (importOpen) loadCandidates()
      focusList()
      fieldFocus.restart()
    } else {
      confirmRemove = ""
      dragUuid = ""
      forgetTimer.restart()
    }
  }

  // Forget anything typed once the panel has been closed for a while.
  function forgetForms() {
    formUser = ""
    formPassword = ""
    editPassword = ""
    promptField.text = ""
    carry = null
    consentRetry = null
    expanded = ""
    editing = ""
    editingGroup = ""
    if (!actionProc.running && !connectProc.running && !browseProc.running) say("", false)
  }

  // Asks the open form (connect form or editor) to focus its first empty field.
  signal focusForm()

  onServiceUpChanged: if (serviceUp) loadProfiles()
  // A form gone (closed, or another opened over it) takes what was typed
  // in it with it.
  onExpandedChanged: if (expanded === "") { formUser = ""; formPassword = "" }
  onEditingChanged: if (editing === "") editPassword = ""
  // Its profile connected from elsewhere: the form goes, and the keyboard
  // with it, rather than staying in a field that's hidden.
  onTunnelsChanged: if (expanded !== "" && live(expanded) !== null) {
    expanded = ""
    formPassword = ""
    focusList()
  }
  // The network's back: try connecting automatically again straight away.
  onNetworkUpChanged: if (networkUp) { autoFailures = 0; lastAutoConnect = 0 }

  // Detached, since installing a plugin reloads it several times in a row and
  // each reload would kill a child process.
  Component.onCompleted: Quickshell.execDetached([backend, "offer-setup"])

  Timer {
    // Quicker while a group connects, to show each hop as it comes up. The
    // first copy checks for all; another asks it while it's open or busy.
    interval: connectProc.running && root.opened ? 1000 : (root.opened || root.transitional) ? 2000 : root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (root.isLeader() || root.opened || root.transitional) root.refresh()
  }

  Timer {
    id: statusFloor
    onTriggered: root.refresh()
  }

  Timer {
    id: confirmTimer
    interval: 3000
    onTriggered: root.confirmRemove = ""
  }

  Timer {
    id: promptFocus
    interval: 200
    onTriggered: if (promptField.visible) promptField.forceActiveFocus()
  }

  // After the panel's own open-time focus handling has run.
  Timer {
    id: fieldFocus
    interval: 200
    onTriggered: {
      if (!root.opened) return
      if (promptField.visible) promptField.forceActiveFocus()
      else root.focusForm()
    }
  }

  Timer {
    id: forgetTimer
    interval: 120000
    onTriggered: root.forgetForms()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string { return root.heroMeta }
    function disconnect(): void { root.disconnect("", true) }
    function connect(name: string): void { root.connectByName(name, false) }
    // on, off or toggle.
    function killSwitch(state: string): void {
      var s = String(state).trim().toLowerCase()
      if (s === "toggle") root.setKillSwitch(!root.killSwitch)
      else if (s === "on" || s === "off") root.setKillSwitch(s === "on")
      else root.notify("Kill switch", "Unknown state \"" + state + "\". Use on, off or toggle.")
    }
    function importFile(path: string): void {
      root.open()
      root.importFiles([path])
    }
  }

  // --- Processes ---

  Process {
    id: statusProc
    property bool busy: false  // started, and not yet exited
    command: [root.backend, "status"]
    onExited: {
      busy = false
      if (root.refreshAgain) { root.refreshAgain = false; Qt.callLater(root.refresh) }
    }
    // Quickshell reports no exit for a process that couldn't start (the
    // script missing or not executable): checked once its stop has settled.
    onRunningChanged: if (!running) Qt.callLater(statusProc.checkStarted)
    function checkStarted() {
      if (running || !busy) return
      busy = false
      root.refreshAgain = false
      var items = root.copies()
      for (var i = 0; i < items.length; i++) items[i].backendBroken = true
    }
    stdout: StdioCollector {
      onStreamFinished: {
        var items = root.copies()
        for (var i = 0; i < items.length; i++)
          if (typeof items[i].applyStatus === "function") items[i].applyStatus(text)
      }
    }
  }

  Process {
    id: profilesProc
    command: [root.backend, "profiles"]
    stdout: StdioCollector { id: profilesOut }
    // A failed listing (NetworkManager restarting, say) keeps the last one.
    onExited: function(exitCode) {
      // With a newer listing on the way, leave a waiting connect to that one.
      var again = root.profilesAgain
      root.profilesAgain = false
      if (again) Qt.callLater(root.loadProfiles)
      var connectTo = again ? "" : root.pendingConnect
      if (!again) root.pendingConnect = ""
      if (exitCode === 0) {
        var list = []
        var lines = profilesOut.text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var f = lines[i].split("\t")
          if (f.length < 18 || f[0] === "") continue
          list.push({ uuid: f[0], kind: f[1], name: f[2], iface: f[3], address: f[4], server: f[5],
                      routes: f[6], allTraffic: f[7] === "1", autoConnect: f[8] === "1", via: f[9],
                      depth: parseInt(f[10], 10) || 0, group: f[11], groupAuto: f[12] === "1",
                      auth: f[13], username: f[14], pwMode: f[15], hasPassword: f[16] === "1", asks: f[17] === "1" })
        }
        root.profiles = list
        if (root.messageUuid !== "" && !root.profile(root.messageUuid)) root.say("", false)
        if (root.editing !== "" && !root.profile(root.editing)) { root.editing = ""; root.focusList() }
        if (root.expanded !== "" && !root.profile(root.expanded)) root.expanded = ""
        // A group that's changed under its editor: not the same group any more.
        if (root.editingGroup !== "" && (!root.profile(root.editingGroup) || !root.inGroup(root.editingGroup)
                                         || root.groupOf(root.editingGroup)[0].uuid !== root.editingGroup)) root.editingGroup = ""
        if (root.pendingSelect !== "" && root.profile(root.pendingSelect)) {
          var uuid = root.pendingSelect
          var note = root.pendingEdit
          root.pendingSelect = ""
          root.pendingEdit = ""
          // Out of the path field before it hides: Qt leaves focus on hidden items.
          keyCatcher.forceActiveFocus()
          root.typing = false
          root.importOpen = false
          root.cursorActive = true
          root.cursor = Math.max(0, root.stopOf(uuid, false))
          root.scrollCursorIntoView()
          if (note !== "" && root.opened) {
            root.openEditor(uuid)
            root.say(note, false)
            Qt.callLater(root.focusForm)
          }
        }
        if (root.carry && !again) {
          var c = root.carry
          root.carry = null
          if (root.profile(c.uuid) && root.expanded !== c.uuid) {
            root.expand(c.uuid)
            root.formPassword = c.password
            root.formSave = false
          }
        }
        if (list.length === 0 && !root.importOpen) root.toggleImport()
        root.cursor = Math.min(root.cursor, root.lastRow)
        pointerGate.reset()
        // The rows are new: a field that had the keyboard may be gone with
        // the old ones. An open form takes it back itself.
        if (root.opened) Qt.callLater(root.regainFocus)
        root.autoConnect()
      }
      if (connectTo !== "") root.connectByName(connectTo, true)
    }
  }

  Process {
    id: candidatesProc
    command: [root.backend, "candidates", root.importFolder]
    stdout: StdioCollector {
      onStreamFinished: {
        var list = []
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var f = lines[i].split("\t")
          if (f.length < 3) continue
          var path = f.slice(2).join("\t")
          list.push({ path: path, file: path.replace(/^.*\//, ""), kind: f[1], mtime: parseInt(f[0], 10) || 0 })
        }
        root.candidates = list
        root.cursor = Math.min(root.cursor, root.lastRow)
      }
    }
  }

  Process {
    id: browseProc
    stdout: StdioCollector {
      onStreamFinished: {
        var paths = text.split("\n").filter(function(p) { return p !== "" })
        root.open()
        if (paths.length > 0) root.importFiles(paths)
      }
    }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim() !== "") { root.open(); root.say(text.trim(), true) }
    }
  }

  // Connecting automatically: no questions can be asked, so what needs one
  // fails, and says so once.
  Process {
    id: autoProc
    property string uuid: ""
    stdout: StdioCollector { id: autoOut }
    stderr: StdioCollector { id: autoErr }
    onExited: function(exitCode) {
      // Stopped (130, or SIGTERM) when something else was connected or it
      // was disconnected: the backend holds it, so it isn't tried again.
      if (exitCode === 0 || exitCode === 130 || exitCode === 143 || exitCode === 15) {
        root.autoFailures = 0
      } else {
        root.autoFailures++
        var p = root.profile(uuid)
        var why = autoErr.text.trim()
        var errors = autoOut.text.split("\n").filter(function(l) { return l.indexOf("error\t") === 0 })
        if (errors.length > 0) why = errors[errors.length - 1].slice(6)
        if (exitCode === 3) why = "Blocked by kill switch until connected from VPN panel once."
        if (p && !root.autoWarned[uuid]) {
          var w = Object.assign({}, root.autoWarned)
          w[uuid] = true
          root.autoWarned = w
          root.notify((root.inGroup(uuid) ? root.groupName(uuid) : p.name) + " didn't connect automatically",
            (why || "Connection failed.") + " Retrying later.")
        }
      }
      root.refreshAll()
    }
  }

  Process {
    id: connectProc
    property string secret: ""
    property string error: ""
    stdinEnabled: true
    onStarted: {
      error = ""
      if (secret !== "") write(secret + "\n")
      secret = ""
    }
    // Couldn't start (see statusProc): the row would stay connecting for good.
    onRunningChanged: if (!running) { secret = ""; Qt.callLater(connectProc.checkStarted) }
    function checkStarted() {
      if (running || root.connectingUuid === "") return
      var uuid = root.connectingUuid
      root.connectingUuid = ""
      root.cancelled = false
      root.prompt = null
      root.consentRetry = null
      root.sayFor(uuid, root.cantRun, true)
      if (!root.opened) root.notify("Couldn't connect", root.cantRun)
      root.refreshAll()
    }
    stdout: SplitParser {
      onRead: function(line) {
        var f = line.split("\t")
        if (f[0] === "prompt") {
          root.showPrompt(f[1] === "1", f[2] || "", f[3] || "")
        } else if (f[0] === "error") {
          connectProc.error = f[1] || ""
          root.sayFor(root.connectingUuid, f[1], true)
        } else if (f[0] === "info") {
          root.sayFor(root.connectingUuid, f[1], false)
        } else if (f[0] === "consent") {
          root.consentUuid = root.connectingUuid
        } else if (f[0] === "status" && f[1] === "Connected") {
          root.say("", false)
          root.refresh()
        }
      }
    }
    stderr: StdioCollector { id: connectErr }
    onExited: function(exitCode) {
      var uuid = root.connectingUuid
      var consent = !root.cancelled && exitCode === 3 && root.consentUuid === uuid
      root.prompt = null
      root.connectingUuid = ""
      if (!consent) root.consentRetry = null
      if (root.cancelled) {
        root.cancelled = false
        // NetworkManager carries on without nmcli, so stop it there too;
        // later, since this process still counts as running until the
        // handler ends.
        // Unless it's being connected again already.
        Qt.callLater(function() {
          if (!root.groupOf(uuid).some(function(q) { return q.uuid === root.connectingUuid })) root.runDisconnect(["disconnect", uuid])
          root.sayFor(uuid, "Cancelled.", false)
        })
      } else if (exitCode === 130) {
        // Stopped from outside the panel; the script already said so.
      } else if (consent) {
        // Set up elsewhere: the next connect of it, from here, gives it the
        // routing table the kill switch lets through.
        root.sayFor(uuid, "Blocked by kill switch: profile was set up outside this plugin and has no routing table of its own. Press Enter or click it again to add one; routing stays the same.", true)
        if (!root.opened) root.notify("Kill switch", (root.profile(uuid) ? root.profile(uuid).name : "It") + " is blocked until connected from VPN panel.")
      } else {
        if (exitCode !== 0 && connectProc.error === "") {
          connectProc.error = connectErr.text.trim() || "Couldn't connect."
          root.sayFor(uuid, connectProc.error, true)
        }
        // Started from a key binding with the panel closed, the error would
        // otherwise go unseen.
        if (exitCode !== 0 && !root.opened) {
          var p = root.profile(uuid)
          root.notify("Couldn't connect" + (p ? " to " + (root.inGroup(uuid) ? root.groupName(uuid) : p.name) : ""), connectProc.error)
        }
        if (exitCode === 0) {
          root.expanded = ""
          root.autoFailures = 0
        } else if (root.expanded === uuid) {
          Qt.callLater(root.focusForm)  // to fix what's wrong and try again
        }
        root.loadProfilesAll()
      }
      root.refreshAll()
    }
  }

  Process {
    id: disconnectProc
    property bool busy: false
    stderr: StdioCollector { id: disconnectErr }
    onRunningChanged: if (!running) Qt.callLater(disconnectProc.checkStarted)
    function checkStarted() {
      if (running || !busy) return
      busy = false
      root.disconnectingUuid = ""
      root.disconnectQueue = []
      root.say(root.cantRun, true)
      if (!root.opened) root.notify("Couldn't disconnect", root.cantRun)
    }
    onExited: function(exitCode) {
      busy = false
      root.disconnectingUuid = ""
      if (exitCode !== 0) {
        root.say(disconnectErr.text.trim() || "Couldn't disconnect.", true)
        if (!root.opened) root.notify("Couldn't disconnect", disconnectErr.text.trim())
      }
      root.refreshAll()
      if (root.disconnectQueue.length > 0) {
        var next = root.disconnectQueue[0]
        root.disconnectQueue = root.disconnectQueue.slice(1)
        Qt.callLater(function() { root.runDisconnect(next) })
      }
    }
  }

  Process {
    id: actionProc
    property string secret: ""
    property bool busy: false
    stdinEnabled: true
    onStarted: {
      if (secret !== "") write(secret + "\n")
      secret = ""
    }
    onRunningChanged: if (!running) { secret = ""; Qt.callLater(actionProc.checkStarted) }
    function checkStarted() {
      if (running || !busy) return
      busy = false
      root.afterAction = ""
      root.carry = null
      root.say(root.cantRun, true)
      if (!root.opened) root.notify("VPN", root.cantRun)
    }
    stdout: StdioCollector { id: actionOut }
    stderr: StdioCollector { id: actionErr }
    onExited: function(exitCode) {
      busy = false
      var then = root.afterAction
      root.afterAction = ""
      if (exitCode !== 0) {
        root.say(actionErr.text.trim() || "That didn't work.", true)
        // From a key binding, with the panel closed.
        if (!root.opened) root.notify("VPN", actionErr.text.trim() || "That didn't work.")
        if (then === "saved") root.carry = null
      } else if (then === "saved") {
        root.editing = ""
        root.editingGroup = ""
        root.editPassword = ""
        if (!root.carry) root.focusList()
        // Only one profile or group connects automatically: say which stopped.
        var stopped = actionOut.text.split("\n").filter(function(l) { return l.indexOf("auto-off\t") === 0 })
          .map(function(l) { return l.slice(9) })
        if (stopped.length > 0)
          root.say(stopped.join(", ") + " no longer connect" + (stopped.length === 1 ? "s" : "")
            + " automatically: only one profile or group can connect automatically.", false)
      } else if (then === "killswitch-on") {
        var blocked = actionOut.text.split("\n").filter(function(l) { return l.indexOf("blocked\t") === 0 })
          .map(function(l) { return l.slice(8) })
        if (blocked.length > 0)
          root.say("Kill switch on. It blocks " + blocked.join(", ") + ", set up outside this plugin: disconnect "
            + (blocked.length === 1 ? "it" : "them") + " and connect again here to let " + (blocked.length === 1 ? "it" : "them") + " through.", true)
        else root.say(root.connected ? "Kill switch on." : "Kill switch on. Connect a profile to access the internet.", false)
      } else if (then === "nested") {
        root.say(root.nestNote + (actionOut.text.indexOf("autoconnect-off") >= 0
          ? " Automatic connection is off: group connects from here only." : ""), false)
      }
      if (then === "pasted" && exitCode === 0) {
        root.pendingSelect = actionOut.text.trim()
        root.pendingEdit = "Imported from clipboard. Give the profile a name and save. Omarchy's clipboard history keeps a copy, keys and all: open it with Super+Ctrl+V and press Delete on it."
      }
      if (then === "imported") {
        var added = actionOut.text.split("\n").filter(function(u) { return u !== "" })
        if (added.length === 1) {
          root.pendingSelect = added[0]
          // An OpenVPN profile wants its username and password next.
          root.pendingEdit = ""
          root.pendingOpenVpn = exitCode === 0 ? added[0] : ""
        }
        if (added.length > 1 && exitCode === 0) root.say("Imported " + added.length + " profiles.", false)
        // A path that failed stays, to be corrected.
        if (exitCode === 0) root.importPath = ""
        root.loadCandidates()
      }
      if (then !== "") root.loadProfilesAll()
      root.refreshAll()
    }
  }

  // A single profile just imported, until the list shows what it is: an
  // OpenVPN profile that needs a password opens its settings; anything
  // else is ready to connect.
  property string pendingOpenVpn: ""
  onProfilesChanged: {
    if (pendingOpenVpn === "") return
    var p = profile(pendingOpenVpn)
    if (!p) return
    pendingOpenVpn = ""
    if (needsPassword(p) && opened) {
      openEditor(p.uuid)
      say("Imported. Enter username and password, then save.", false)
      Qt.callLater(focusForm)
    } else {
      say("Imported. Press Enter or click to connect.", false)
    }
  }

  // --- Bar icon ---

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    tooltipText: root.barTooltip
    foreground: root.silent || (root.partly && !root.transitional) ? root.urgent
      : root.connected ? root.barForeground : Qt.darker(root.barForeground, 1.55)
    opacity: root.transitional ? pulse.value : 1.0
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  QtObject {
    id: pulse
    property real value: 1.0
    SequentialAnimation on value {
      running: root.transitional
      loops: Animation.Infinite
      NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
    }
  }

  // --- Panel ---

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.typing
      // Back on the list however it got here (a field it was in destroyed).
      onActiveFocusChanged: if (activeFocus) root.typing = false
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.nestStep(dx)
      }
      // The first key just shows the cursor, so nothing happens to a row the
      // user can't see is selected.
      onActivateRequested: {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.activateCursor()
      }
      onCloseRequested: {
        if (root.prompt) root.cancelConnect()
        else if (root.editing !== "") root.closeEditor()
        else if (root.editingGroup !== "") root.closeGroupEditor()
        else if (root.expanded !== "") root.expand(root.expanded)
        else if (root.importOpen && root.profiles.length > 0) root.toggleImport()
        else root.close()
      }
      onDeleteRequested: {
        if (!root.cursorActive) { root.cursorActive = true; return }
        var s = root.cursorStop()
        var p = root.cursorProfile()
        if (!s || actionProc.running) return
        if (s.header) root.say("Select a profile in the group to remove it.", true)
        else if (root.live(p.uuid) || root.connectingUuid === p.uuid) root.say("Disconnect " + p.name + " before removing.", true)
        else root.removeProfile(p.uuid)
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // On a group's name, e edits the group and d disconnects it; on one of
      // its profiles, e and c edit that profile, and d still disconnects the
      // group, which goes on and off as one.
      onTextKey: function(key) {
        var t = key.toLowerCase()
        var s = root.cursorStop()
        var p = root.cursorProfile()
        if (t === "i" || t === "n") root.toggleImport(true)
        else if (t === "b") root.browse()
        else if (t === "p") root.pasteConfig()
        else if (t === "e" && s) { if (s.header) root.openGroupEditor(s.uuid); else root.openEditor(s.uuid) }
        else if (t === "c" && p) root.editConfig(p.uuid)
        else if (t === "d" && s) {
          // The group it's in, up or on its way up; nothing else.
          var u = root.upIn(s.uuid)
          if (u === "" && root.groupOf(s.uuid).some(function(q) { return q.uuid === root.connectingUuid })) u = s.uuid
          if (u !== "") root.disconnect(u)
        }
        else if (t === "d" && (root.tunnels.length > 0 || connectProc.running)) root.disconnect("")
        else if (t === "s" && (!root.installed || (!root.openvpnInstalled && root.profiles.some(function(q) { return q.kind === "ovpn" })))) root.runSetup()
        else if (t === "r") { root.refresh(); root.loadProfiles(); if (root.importOpen) root.loadCandidates() }
        // With Caps Lock on, j and k come in as capitals.
        else if (key === "J" || key === "K") keyCatcher.moveRequested(0, key === "J" ? 1 : -1)
      }

      // Shift+K only: with Caps Lock on, k comes in as "K" too.
      Shortcut {
        sequence: "Shift+K"
        enabled: root.opened && !root.typing
        onActivated: root.setKillSwitch(!root.killSwitch)
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        // It scrolls with the wheel, the touchpad, the scroll bar and the
        // cursor, but not by dragging with the mouse: dragging moves profiles.
        acceptedButtons: Qt.NoButton
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "VPN"
            meta: root.heroMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.connected ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.glyph
                color: root.silent ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ActionButton {
                visible: root.tunnels.length > 0 || connectProc.running
                text: root.connectionCount > 1 || (root.connectionCount > 0 && connectProc.running) ? "Disconnect all"
                  : root.connectionCount > 0 ? "Disconnect" : "Cancel"
                onClicked: root.disconnect("")
              }
            }
          }

          // Not installed / NetworkManager off: one clear way forward.
          Notice {
            visible: root.loaded && !root.installed
            title: "Some packages are missing"
            detail: "Setup installs " + root.missing + " (asks first). Plugin runs VPNs through NetworkManager."
            action: "Run setup"
            onTriggered: root.runSetup()
          }

          Notice {
            visible: root.loaded && root.installed && !root.serviceUp
            title: "NetworkManager isn't running"
            detail: "VPN profiles are NetworkManager connections, so NetworkManager must be running."
          }

          Notice {
            visible: root.serviceUp && !root.openvpnInstalled && root.profiles.some(function(p) { return p.kind === "ovpn" })
            title: "OpenVPN isn't installed"
            detail: "OpenVPN profiles can't connect without networkmanager-openvpn. Setup installs it (asks first)."
            action: "Run setup"
            onTriggered: root.runSetup()
          }

          // Live connection details.
          Column {
            visible: root.connected && root.primary !== null
            width: parent.width
            spacing: Style.spacing.labelGap
            InfoPair { visible: root.upList.length > 1; label: "Showing"; value: root.primary ? root.primary.name : "" }
            InfoPair {
              visible: root.routeTo(root.primary) !== ""
              label: "Route"
              value: root.routeTo(root.primary) + " › " + (root.primary ? root.primary.name : "")
            }
            InfoPair { label: "Address"; value: root.primary && root.primary.ip ? root.primary.ip : "—" }
            InfoPair {
              label: "Server"
              value: root.primary && root.profile(root.primary.uuid) ? root.profile(root.primary.uuid).server || "—" : "—"
            }
            InfoPair { label: "Connected for"; value: root.primary ? root.formatDuration(root.primary.secs) : "—" }
            InfoPair {
              label: "Traffic"
              value: root.primary ? "↑ " + root.formatBytes(root.primary.sent) + "   ↓ " + root.formatBytes(root.primary.recv) : "—"
            }
          }

          Text {
            visible: root.silent
            width: parent.width
            textFormat: Text.PlainText
            text: "Nothing received through WireGuard tunnel. Check that server is up, address and port are correct, and this network isn't blocking it."
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }

          // A question from NetworkManager mid-connect: a key's password, a
          // one-time code...
          Column {
            id: promptBox
            visible: root.prompt !== null
            width: parent.width
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: text !== ""
              text: root.prompt ? root.prompt.context : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.prompt ? (root.profile(root.connectingUuid) ? root.profile(root.connectingUuid).name + ": " : "") + root.prompt.text : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              wrapMode: Text.Wrap
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)
              Field {
                id: promptField
                Layout.fillWidth: true
                password: root.prompt ? root.prompt.secret : false
                placeholderText: "Answer"
                onAccepted: { var t = text; text = ""; root.answerPrompt(t) }
                Keys.onEscapePressed: { text = ""; root.cancelConnect() }
              }
              ActionButton {
                text: "Send"
                onClicked: { var t = promptField.text; promptField.text = ""; root.answerPrompt(t) }
              }
            }
          }

          // The forms show their own messages, next to them.
          Message { visible: root.message !== "" && root.editing === "" && root.editingGroup === "" && !root.messageInForm; width: parent.width }

          PanelSeparator {
            visible: root.serviceUp
            foreground: root.foreground
          }

          Column {
            visible: root.serviceUp
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "PROFILES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.profiles.length === 0
              width: parent.width
              textFormat: Text.PlainText
              text: "No VPN profiles yet. Import a WireGuard .conf or OpenVPN .ovpn file from your VPN provider or admin."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            Repeater {
              id: blockRepeater
              model: root.blocks
              GroupBlock {
                required property var modelData
                required property int index
                width: parent.width
                block: modelData
                blockIndex: index
              }
            }

            // While a profile in a group is dragged: somewhere to drop it to
            // take it out. Anywhere that isn't a profile does the same, and
            // lights this up.
            CursorSurface {
              visible: root.dragUuid !== "" && root.dragCanLeave
              width: parent.width
              implicitHeight: outText.implicitHeight + Style.spacing.rowPaddingX * 2
              foreground: root.foreground
              bordered: true
              hasCursor: root.dropsOut
              Text {
                id: outText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "Drop here to remove from group"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            CursorSurface {
              id: importRowItem
              width: parent.width
              implicitHeight: importText.implicitHeight + Style.spacing.rowPaddingX
              foreground: root.foreground
              hasCursor: root.cursorActive && root.cursor === root.importRow
              current: root.importOpen

              MouseArea {
                id: importMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: function(mouse) {
                  if (pointerGate.moved(importMouse, mouse)) { root.cursorActive = true; root.cursor = root.importRow }
                }
                onClicked: root.toggleImport()
              }
              Text {
                id: importText
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                x: Style.space(10)
                text: "+  Import profile"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            ImportBox { id: importBox; visible: root.importOpen; width: parent.width }
          }

          PanelSeparator {
            visible: root.serviceUp
            foreground: root.foreground
          }

          Column {
            visible: root.serviceUp
            width: parent.width
            spacing: Style.space(4)
            Option {
              label: "Kill switch"
              checked: root.killSwitch
              activeFocusOnTab: false
              onToggled: root.setKillSwitch(!root.killSwitch)
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.killSwitch
                ? "Internet traffic must go through a VPN tunnel. Local networks excluded."
                : "Blocks internet if VPN drops."
              color: root.killSwitch && !root.connected ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }
        }
      }
    }
  }

  // --- Components ---

  component Field: TextField {
    foreground: root.foreground
    font.family: root.fontFamily
    verticalPadding: Style.spacing.controlPaddingY
    onActiveFocusChanged: root.typing = activeFocus
    // A text field emits accepted on Enter and then passes the key on, and
    // keyCatcher would take it as "activate the row under the cursor" (which
    // could cancel the connection that Enter just started). Stop it here,
    // after the field has handled it.
    Keys.priority: Keys.AfterItem
    Keys.onReturnPressed: function(event) { event.accepted = true }
    Keys.onEnterPressed: function(event) { event.accepted = true }
  }

  // A button that looks unavailable when it is: Ui's Button only stops clicks.
  component ActionButton: Button {
    bordered: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    opacity: enabled ? 1.0 : 0.4
  }

  // A labelled switch. Tab reaches it; Space or Enter flips it, and Escape
  // leaves the form, like the fields around it.
  component Option: Item {
    id: option
    property string label: ""
    property bool checked: false
    signal toggled()
    signal escaped()
    implicitWidth: optionRow.implicitWidth
    implicitHeight: optionRow.implicitHeight
    activeFocusOnTab: visible
    onActiveFocusChanged: root.typing = activeFocus
    Keys.onSpacePressed: option.toggled()
    Keys.onReturnPressed: option.toggled()
    Keys.onEnterPressed: option.toggled()
    Keys.onEscapePressed: option.escaped()
    // Other keys stop here rather than reach the list behind the form.
    Keys.onPressed: function(event) { if (event.key !== Qt.Key_Tab && event.key !== Qt.Key_Backtab) event.accepted = true }
    Row {
      id: optionRow
      spacing: Style.space(6)
      ToggleSwitch {
        anchors.verticalCenter: parent.verticalCenter
        trackHeight: Style.space(14)
        hasCursor: option.activeFocus
        checked: option.checked
        foreground: root.foreground
        onToggled: option.toggled()
      }
      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: option.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: option.toggled() }
      }
    }
  }

  // One of a few options, picked in place: ← → (h l), Space or Enter step
  // through them, as do clicks on the arrows. Tab reaches it, like the
  // switch, and Escape leaves the form.
  component Choice: Item {
    id: choice
    property string label: ""
    property var options: []    // { value, label }
    property string value: ""
    readonly property int at: Math.max(0, options.findIndex(function(o) { return o.value === choice.value }))
    signal picked(string value)
    signal escaped()
    implicitHeight: choiceRow.implicitHeight + Style.space(4)
    activeFocusOnTab: visible
    onActiveFocusChanged: root.typing = activeFocus

    function step(d) {
      if (options.length > 1) picked(options[(at + d + options.length) % options.length].value)
    }

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) return
      // Other keys stop here rather than reach the list behind the form.
      event.accepted = true
      if (event.key === Qt.Key_Escape) choice.escaped()
      else if (event.key === Qt.Key_Left || event.text === "h") choice.step(-1)
      else if (event.key === Qt.Key_Right || event.text === "l" || event.key === Qt.Key_Space
               || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) choice.step(1)
    }

    CursorSurface {
      anchors.fill: parent
      foreground: root.foreground
      hasCursor: choice.activeFocus
    }

    RowLayout {
      id: choiceRow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(4)
      spacing: Style.space(2)
      Text {
        textFormat: Text.PlainText
        text: choice.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Item { Layout.fillWidth: true; implicitWidth: Style.space(8) }
      PanelActionButton {
        iconText: "󰅁"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: choice.options.length > 1
        onClicked: choice.step(-1)
      }
      Text {
        Layout.maximumWidth: choice.width * 0.6
        textFormat: Text.PlainText
        text: choice.options.length > 0 ? choice.options[choice.at].label : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideLeft
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: choice.step(1) }
      }
      PanelActionButton {
        iconText: "󰅂"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: choice.options.length > 1
        onClicked: choice.step(1)
      }
    }
  }

  // Where a dragged profile would go: a faint line, which starts with ↳
  // when it goes in under the profile above.
  component DropLine: Item {
    id: dropLine
    property bool under: false
    height: Math.max(arrow.implicitHeight, 1)
    z: 10
    opacity: 0.7
    Text {
      id: arrow
      visible: dropLine.under
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: "↳"
      color: Color.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      x: dropLine.under ? arrow.implicitWidth + Style.space(3) : 0
      width: parent.width - x
      height: 1
      color: Color.accent
    }
  }

  component Notice: RowLayout {
    id: notice
    property string title: ""
    property string detail: ""
    property string action: ""
    signal triggered()
    width: parent.width
    spacing: Style.space(8)
    Column {
      Layout.fillWidth: true
      spacing: Style.space(2)
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: notice.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.Wrap
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: notice.detail
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }
    }
    ActionButton {
      visible: notice.action !== ""
      text: notice.action
      onClicked: notice.triggered()
    }
  }

  // Clicking a row connects or disconnects it. Dragging it onto another
  // nests it inside that one.
  component ProfileRow: Column {
    id: row
    property var p: ({})
    property int rowIndex: 0            // its place in profiles
    property bool inBox: false          // in a group's box
    readonly property var liveState: root.live(p.uuid)
    readonly property bool isLive: liveState !== null
    readonly property bool isUp: isLive && liveState.state === "connected"
    readonly property bool isConnecting: root.connectingUuid !== "" && root.groupOf(p.uuid).some(function(q) { return q.uuid === root.connectingUuid })
    readonly property bool isDisconnecting: root.disconnectingUuid !== "" && root.groupOf(p.uuid).some(function(q) { return q.uuid === root.disconnectingUuid })
    readonly property bool isDragged: root.dragUuid === p.uuid
    readonly property bool asksPassword: root.needsPassword(p)
    spacing: Style.space(6)

    CursorSurface {
      visible: root.editing !== row.p.uuid
      width: parent.width
      implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX
      foreground: root.foreground
      // While dragging, the profile it would go under; otherwise the cursor.
      hasCursor: root.dragUuid !== "" ? root.dropsUnder(row.p.uuid) : root.cursorOn(row.p.uuid, false)
      current: (row.isUp && !row.inBox) || root.expanded === row.p.uuid
      opacity: row.isDragged ? 0.6 : 1.0

      // Dropped on its group's name: in front of this, the first profile.
      DropLine {
        visible: root.dropsAbove(row.p.uuid)
        anchors.verticalCenter: parent.top
        anchors.verticalCenterOffset: -Style.space(2)
        x: Style.space(10)
        width: parent.width - x - Style.space(6)
      }

      DropLine {
        visible: root.dropsUnder(row.p.uuid)
        under: true
        anchors.verticalCenter: parent.bottom
        anchors.verticalCenterOffset: Style.space(2)
        x: Style.space(10) + row.p.depth * Style.space(14)
        width: parent.width - x - Style.space(6)
      }

      MouseArea {
        id: rowMouse
        property real pressX: 0
        property real pressY: 0
        property bool dragged: false
        anchors.fill: parent
        hoverEnabled: true
        preventStealing: true
        cursorShape: root.dragUuid !== "" ? Qt.ClosedHandCursor : Qt.PointingHandCursor
        onPressed: function(mouse) { pressX = mouse.x; pressY = mouse.y; dragged = false }
        onPositionChanged: function(mouse) {
          if (!pressed) { root.pointAt(row.p.uuid, false, rowMouse, mouse); return }
          if (!dragged) {
            if (Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) < Style.space(8)) return
            dragged = true
            root.dragUuid = row.p.uuid
            root.dropVia = row.p.uuid
            root.dropAbove = ""
          }
          root.dragOver(rowMouse, mouse.x, mouse.y)
        }
        onReleased: if (dragged) root.drop()
        onCanceled: root.dragUuid = ""
        // A drag that ends on the row it started on isn't a click.
        onClicked: if (!dragged) root.toggleProfile(row.p.uuid)
      }

      RowLayout {
        id: rowContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10) + Math.max(0, row.p.depth - 1) * Style.space(14)
        anchors.rightMargin: Style.space(4)
        spacing: Style.space(6)

        Text {
          visible: row.p.depth > 0
          Layout.alignment: Qt.AlignTop
          textFormat: Text.PlainText
          text: "↳"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Column {
          Layout.fillWidth: true
          spacing: Style.space(1)
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: row.p.name
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: row.isLive
            elide: Text.ElideRight
          }
          Text {
            readonly property bool warn: root.confirmRemove === row.p.uuid || (row.isUp && root.noReply(row.liveState))
              || (row.isDragged && root.dropBusy !== "")
            textFormat: Text.PlainText
            width: parent.width
            text: row.isDragged ? (!root.dropMoves ? "Drop under another profile"
                : root.dropBusy !== "" ? "Disconnect " + root.dropBusy + " before moving"
                : root.dropAbove !== "" ? "Drop above " + root.profile(root.dropAbove).name
                : root.dropVia === "" ? "Drop to remove from group"
                : root.childOf(root.dropVia) && root.childOf(root.dropVia).uuid !== row.p.uuid
                  ? "Drop between " + root.profile(root.dropVia).name + " and " + root.childOf(root.dropVia).name
                : "Drop under " + root.profile(root.dropVia).name)
              : root.confirmRemove === row.p.uuid ? "Press again to remove profile"
              : row.isDisconnecting ? (row.isLive ? "Disconnecting…" : "Disconnected")
              // A group connects one hop at a time: each waits for the one before.
              : row.isConnecting && !row.isLive ? (row.inBox ? "Waiting" : "Connecting…")
              : row.isConnecting && (row.liveState.state !== "connected"
                               || (row.p.kind === "wg" && Number(row.liveState.recv) === 0)) ? "Connecting…"
              : row.isUp && root.noReply(row.liveState) ? "No reply from server"
              : row.isUp && root.carried(row.liveState) ? "Carrying " + root.carried(row.liveState).name
              : row.isUp ? "Connected" + (row.liveState.ip ? " · " + row.liveState.ip : "")
              : row.isLive ? (row.liveState.state === "disconnecting" ? "Disconnecting…" : "Connecting…")
              // The server last: it's the longest, and in full in the settings.
              : [root.kindLabel(row.p.kind)].concat(row.p.autoConnect ? ["auto"] : [], row.p.allTraffic ? [] : ["split"],
                  row.asksPassword && row.p.username ? [row.p.username] : [], [row.p.server || "No server address"]).join(" · ")
            color: warn ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        PanelActionButton {
          iconText: "󰏫"
          tooltipText: "Edit (e)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.openEditor(row.p.uuid)
        }
        PanelActionButton {
          iconText: "󰆴"
          tooltipText: "Remove (x)"
          foreground: root.foreground
          hoverColor: root.urgent
          fontFamily: root.fontFamily
          enabled: !actionProc.running && !row.isLive && !row.isConnecting
          onClicked: root.removeProfile(row.p.uuid)
        }
      }
    }

    // An OpenVPN profile's connect form, below its row: made only while
    // it's open. One remade with the list takes the keyboard back.
    Loader {
      active: root.expanded === row.p.uuid && !row.isLive && root.editing === ""
      // A Loader keeps its last item's height once inactive: hidden, the
      // Column leaves no gap for it.
      visible: active
      width: parent.width
      sourceComponent: connectForm
    }

    Component {
      id: connectForm
      Column {
        id: form
        Component.onCompleted: Qt.callLater(form.takeFocus)
        function takeFocus() {
          if (userField.visible && userField.text === "") userField.forceActiveFocus()
          else if (passField.visible) passField.forceActiveFocus()
        }
        leftPadding: Style.space(10)
        rightPadding: Style.space(10)
        spacing: Style.space(6)
        readonly property real innerWidth: width - leftPadding - rightPadding

        Field {
          id: userField
          visible: row.asksPassword && row.p.username === ""
          width: parent.innerWidth
          placeholderText: "Username"
          text: root.formUser
          onTextChanged: root.formUser = text
          onAccepted: passField.forceActiveFocus()
          Keys.onEscapePressed: root.expand(row.p.uuid)
        }

        Field {
          id: passField
          visible: row.asksPassword
          width: parent.innerWidth
          password: true
          placeholderText: row.p.hasPassword ? "Saved password (type to replace)" : "Password"
          text: root.formPassword
          onTextChanged: root.formPassword = text
          onAccepted: root.connectWithForm(row.p.uuid)
          Keys.onEscapePressed: root.expand(row.p.uuid)
        }

        Connections {
          target: root
          function onFocusForm() { form.takeFocus() }
        }

        Option {
          visible: row.asksPassword
          label: "Save password"
          checked: root.formSave
          onToggled: root.formSave = !root.formSave
          onEscaped: root.expand(row.p.uuid)
        }

        Text {
          visible: !row.asksPassword
          width: parent.innerWidth
          textFormat: Text.PlainText
          text: root.typeLabel(row.p.auth) + " login" + (row.p.asks ? ". Private key password is asked for at each connect." : ".")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        Message { visible: root.message !== "" && root.messageInForm; width: parent.innerWidth }

        ActionButton {
          text: "Connect"
          enabled: !connectProc.running
          onClicked: root.connectWithForm(row.p.uuid)
        }
      }
    }

    Loader {
      active: root.editing === row.p.uuid
      visible: active
      width: parent.width
      sourceComponent: Component { Editor { p: row.p } }
    }
  }

  // A profile on its own, or a group: its name, then its profiles, in a
  // box. The cursor stops on each; on the name, it lights up the box as a
  // whole.
  component GroupBlock: Item {
    id: blk
    property var block: ({ members: [] })
    property int blockIndex: 0          // its place in blocks
    readonly property bool grouped: block.members.length > 1
    readonly property var head: block.members.length > 0 ? block.members[0].p : ({})
    readonly property real pad: grouped ? Style.space(4) : 0
    readonly property Item headerItem: groupHeader
    implicitHeight: inner.implicitHeight + pad * 2

    // The highlight follows the pointer in (the rows and name take it), and
    // goes when it leaves.
    HoverHandler {
      onHoveredChanged: {
        var s = root.cursorStop()
        if (!hovered && root.dragUuid === "" && s && s.block === blk.blockIndex) root.cursorActive = false
      }
    }

    function rowFor(i) {
      for (var k = 0; k < memberRepeater.count; k++) {
        var r = memberRepeater.itemAt(k)
        if (r && r.rowIndex === i) return r
      }
      return null
    }

    CursorSurface {
      visible: blk.grouped
      anchors.fill: parent
      foreground: root.foreground
      bordered: true
      // While dragging, lit when it would go first in this group.
      hasCursor: root.dragUuid !== "" ? root.dropsAbove(blk.head.uuid) : root.cursorOn(blk.head.uuid, true)
    }

    Column {
      id: inner
      x: blk.pad
      y: blk.pad
      width: parent.width - blk.pad * 2
      spacing: Style.space(4)

      // The group's name: clicking it, like clicking any of its profiles,
      // connects or disconnects the group.
      RowLayout {
        id: groupHeader
        visible: blk.grouped
        width: parent.width
        spacing: Style.space(6)
        Text {
          Layout.fillWidth: true
          leftPadding: Style.space(6)
          textFormat: Text.PlainText
          text: blk.grouped ? root.groupName(blk.head.uuid) : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
          MouseArea {
            id: headerMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPositionChanged: function(mouse) { root.pointAt(blk.head.uuid, true, headerMouse, mouse) }
            onClicked: root.toggleProfile(blk.head.uuid)
          }
        }
        Text {
          visible: blk.head.groupAuto === true
          textFormat: Text.PlainText
          text: "auto"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        PanelActionButton {
          iconText: "󰏫"
          tooltipText: "Edit group (e)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.openGroupEditor(blk.head.uuid)
        }
      }

      Loader {
        active: blk.grouped && root.editingGroup === blk.head.uuid
        visible: active
        width: parent.width
        sourceComponent: Component { GroupEditor { head: blk.head } }
      }

      Repeater {
        id: memberRepeater
        model: blk.block.members
        ProfileRow {
          required property var modelData
          width: parent.width
          p: modelData.p
          rowIndex: modelData.index
          inBox: blk.grouped
        }
      }
    }
  }

  component GroupEditor: Column {
    id: groupEditor
    property var head: ({})
    spacing: Style.space(6)
    leftPadding: Style.space(6)
    rightPadding: Style.space(6)
    readonly property real innerWidth: width - leftPadding - rightPadding
    Component.onCompleted: Qt.callLater(function() { groupField.forceActiveFocus() })

    Connections {
      target: root
      function onFocusForm() { groupField.forceActiveFocus() }
    }

    Field {
      id: groupField
      width: groupEditor.innerWidth
      placeholderText: "Group name: " + root.groupOf(groupEditor.head.uuid || "").map(function(p) { return p.name }).join(" › ")
      text: root.editGroupName
      onTextChanged: root.editGroupName = text
      Keys.onEscapePressed: root.closeGroupEditor()
      onAccepted: root.saveGroupEditor()
    }

    Option {
      label: "Connect automatically"
      checked: root.editGroupAuto
      onToggled: root.editGroupAuto = !root.editGroupAuto
      onEscaped: root.closeGroupEditor()
    }

    Text {
      visible: root.editGroupAuto
      width: groupEditor.innerWidth
      textFormat: Text.PlainText
      text: "Connects at login. Reconnects if connection drops. Manually disconnecting or connecting another profile disconnects until next login."
        + root.autoNote(groupEditor.head.uuid || "")
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }

    Message { visible: root.message !== ""; width: groupEditor.innerWidth }

    RowLayout {
      width: groupEditor.innerWidth
      spacing: Style.space(6)
      ActionButton {
        text: "Save"
        enabled: !actionProc.running
        onClicked: root.saveGroupEditor()
      }
      ActionButton {
        text: "Cancel"
        bordered: false
        onClicked: root.closeGroupEditor()
      }
      Item { Layout.fillWidth: true }
    }
  }

  component Editor: Column {
    id: editor
    property var p: ({})
    readonly property bool openvpn: p.kind === "ovpn"
    readonly property bool asksPassword: root.needsPassword(p)
    readonly property bool grouped: root.editVia !== "" || root.childOf(p.uuid || "") !== null
    spacing: Style.space(6)
    // Made when it opens, and again when a changed list rebuilds the rows.
    Component.onCompleted: Qt.callLater(function() { nameField.forceActiveFocus() })

    PanelSectionHeader {
      text: "EDIT " + (editor.p.name || "").toUpperCase()
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Column {
      width: parent.width
      spacing: Style.spacing.labelGap
      InfoPair { label: "Type"; value: root.kindLabel(editor.p.kind) + (editor.openvpn ? " · " + root.typeLabel(editor.p.auth) : "") }
      InfoPair { label: "Server"; value: editor.p.server || "—" }
      InfoPair { visible: !editor.openvpn; label: "Address"; value: editor.p.address || "—" }
      InfoPair {
        visible: !editor.openvpn
        label: "Routes"
        value: editor.p.allTraffic ? "All traffic" : editor.p.routes || "—"
      }
      InfoPair { visible: !editor.openvpn; label: "Interface"; value: editor.p.iface || "—" }
    }

    Field {
      id: nameField
      width: parent.width
      placeholderText: "Profile name"
      text: root.editName
      onTextChanged: root.editName = text
      Keys.onEscapePressed: root.closeEditor()
      onAccepted: editor.asksPassword ? editUserField.forceActiveFocus() : root.saveEditor()
    }

    Field {
      id: editUserField
      visible: editor.asksPassword
      width: parent.width
      placeholderText: "Username"
      text: root.editUser
      onTextChanged: root.editUser = text
      Keys.onEscapePressed: root.closeEditor()
      onAccepted: editPassField.forceActiveFocus()
    }

    Field {
      id: editPassField
      visible: editor.asksPassword
      width: parent.width
      password: true
      placeholderText: root.editMode === "save" && editor.p.hasPassword ? "Saved password (type to replace)" : "Password"
      text: root.editPassword
      onTextChanged: root.editPassword = text
      Keys.onEscapePressed: root.closeEditor()
      onAccepted: root.saveEditor()
    }

    // Off means it's asked for each time it connects.
    Option {
      visible: editor.asksPassword
      label: "Save password"
      checked: root.editMode === "save"
      onToggled: root.setEditSave(root.editMode !== "save")
      onEscaped: root.closeEditor()
    }

    Connections {
      target: root
      function onFocusForm() {
        if (editUserField.visible && editUserField.text === "") editUserField.forceActiveFocus()
        else if (editPassField.visible && !editor.p.hasPassword) editPassField.forceActiveFocus()
        else nameField.forceActiveFocus()
      }
    }

    Choice {
      width: parent.width
      label: "Through"
      options: root.viaOptions(editor.p.uuid)
      value: root.editVia
      onPicked: function(value) { root.editVia = value }
      onEscaped: root.closeEditor()
    }

    // A profile in a group connects with it only.
    Option {
      visible: !editor.grouped
      label: "Connect automatically"
      checked: root.editAuto
      onToggled: root.setEditAuto(!root.editAuto)
      onEscaped: root.closeEditor()
    }

    Text {
      visible: editor.grouped || root.editAuto
      width: parent.width
      textFormat: Text.PlainText
      text: editor.grouped
        ? "Connects and disconnects with the group. To name the group, or have the group connect automatically, edit the group directly using e or the edit button."
          + (editor.asksPassword && !(root.editMode === "save" && (editor.p.hasPassword || root.editPassword !== ""))
             ? " Password must be saved for profiles in a group." : "")
        : (editor.openvpn
           ? "Connects at login. Reconnects if connection drops. Manually disconnecting or connecting another profile disconnects until next login."
           : "Connects at boot. Reconnects if connection drops. Manually disconnecting or connecting another profile disconnects until next login or reboot.")
          + root.autoNote(editor.p.uuid || "")
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }

    Option {
      visible: editor.openvpn
      label: "Send all traffic through VPN"
      checked: root.editAll
      onToggled: root.editAll = !root.editAll
      onEscaped: root.closeEditor()
    }

    Text {
      visible: editor.openvpn
      width: parent.width
      textFormat: Text.PlainText
      text: root.editAll ? "DNS included." : "Only VPN's own networks."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }

    // Saving changes the profile in NetworkManager; a connection already up
    // keeps the settings it started with.
    Text {
      visible: root.live(editor.p.uuid || "") !== null
      width: parent.width
      textFormat: Text.PlainText
      text: "Changes apply at next connect."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }

    Message { visible: root.message !== ""; width: parent.width }

    RowLayout {
      width: parent.width
      spacing: Style.space(6)
      ActionButton {
        text: "Save"
        enabled: !actionProc.running
        onClicked: root.saveEditor()
      }
      ActionButton {
        text: "Cancel"
        bordered: false
        onClicked: root.closeEditor()
      }
      Item { Layout.fillWidth: true }
      ActionButton {
        text: "Edit config…"
        bordered: false
        onClicked: root.editConfig(editor.p.uuid)
      }
    }
  }

  component ImportBox: Column {
    id: importBox
    spacing: Style.space(6)
    leftPadding: Style.space(10)
    rightPadding: Style.space(10)
    readonly property real innerWidth: width - leftPadding - rightPadding

    function rowAt(i) { return candidateRepeater.itemAt(i) }
    function focusPath() { if (importBox.visible) pathField.forceActiveFocus() }

    RowLayout {
      width: importBox.innerWidth
      spacing: Style.space(6)
      Field {
        id: pathField
        Layout.fillWidth: true
        placeholderText: "Path to a .conf or .ovpn file"
        text: root.importPath
        onTextChanged: {
          // A config pasted here: import it from the clipboard, as Paste
          // config does, and don't leave its keys in the field. A plain
          // assignment also clears the field's undo history.
          if (/\[interface\]/i.test(text) || /^\s*(client|remote)\s/m.test(text) || /<(ca|cert|key)>/.test(text)) {
            root.importPath = ""
            text = ""
            text = Qt.binding(function() { return root.importPath })
            root.pasteConfig()
            return
          }
          root.importPath = text
        }
        onAccepted: root.importFiles([text.trim()])
        Keys.onEscapePressed: root.toggleImport()
        Keys.onDownPressed: {
          root.cursorActive = true
          root.cursor = Math.min(root.lastRow, root.importRow + 1)
          root.focusList()
        }
      }
      ActionButton {
        text: "Browse…"
        enabled: !browseProc.running
        onClicked: root.browse()
      }
    }

    ActionButton {
      width: importBox.innerWidth
      text: "Paste config"
      enabled: !actionProc.running
      onClicked: root.pasteConfig()
    }

    RowLayout {
      visible: !root.openvpnInstalled
      width: importBox.innerWidth
      spacing: Style.space(6)
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: "OpenVPN profiles need networkmanager-openvpn installed."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }
      ActionButton {
        text: "Run setup"
        onClicked: root.runSetup()
      }
    }

    Text {
      width: importBox.innerWidth
      textFormat: Text.PlainText
      text: root.candidates.length > 0 ? "Found in " + root.importFolder + ":"
        : "No WireGuard or OpenVPN files in " + root.importFolder + "."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }

    Repeater {
      id: candidateRepeater
      model: root.candidates
      CursorSurface {
        id: candidateRow
        required property var modelData
        required property int index
        readonly property int rowIndex: root.importRow + 1 + index
        width: importBox.innerWidth
        implicitHeight: candidateText.implicitHeight + Style.spacing.rowPaddingX
        foreground: root.foreground
        hasCursor: root.cursorActive && root.cursor === rowIndex
        MouseArea {
          id: candidateMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          enabled: !actionProc.running
          onPositionChanged: function(mouse) {
            if (pointerGate.moved(candidateMouse, mouse)) { root.cursorActive = true; root.cursor = candidateRow.rowIndex }
          }
          onClicked: root.importFiles([candidateRow.modelData.path])
        }
        RowLayout {
          id: candidateText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(8)
          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: candidateRow.modelData.file
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideMiddle
          }
          Text {
            textFormat: Text.PlainText
            text: root.kindLabel(candidateRow.modelData.kind) + " · " + root.formatAge(candidateRow.modelData.mtime)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  component Message: Text {
    textFormat: Text.PlainText
    text: root.message
    color: root.messageIsError ? root.urgent : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
  }

  component InfoPair: RowLayout {
    property string label: ""
    property string value: ""
    width: parent.width
    spacing: Style.space(8)
    Text {
      textFormat: Text.PlainText
      text: parent.label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      horizontalAlignment: Text.AlignRight
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }
}
