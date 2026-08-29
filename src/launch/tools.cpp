// macOS: the quickshell Mach-O is also the launcher for every tool that ships
// inside Quickshell.app -- the Linux commands end-4's config shells out to by
// bare name (hyprctl, notify-send, pidof, ...) and the qs-* helpers. Three
// forms reach a tool, each ending in execv of
// Quickshell.app/Contents/Resources/tools/<name>:
//
//   argv[0] multicall    bin/<name> is a symlink onto bin/qs, which execs this
//                        binary with argv[0] = <name>
//   qs <name> [args]     subcommand form
//   qs --tools           list them
//
// Before that, the process sets what macOS does not give quickshell for free
// (bin/qs used to do this in bash): PATH with the tools dir first,
// XDG_RUNTIME_DIR, QML2_IMPORT_PATH for the shims, and the default config
// name. Tools inherit the lot, so a tool calling back into `qs` lands on the
// same instance as everything else. All POSIX, no Qt: this runs before
// QCoreApplication exists, and a dispatched tool never pays for one.
#include "launch_p.hpp"

#include <algorithm>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <dirent.h>
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <unistd.h>

namespace qs::launch::macos {

namespace {

// Configs are directories under ~/.config/quickshell; this is the one a bare
// `qs` (and every `qs ipc call` that must find the same instance) runs. The
// only place the name is written down.
constexpr const char* DEFAULT_CONFIG = "end4";

std::string dirName(const std::string& path) {
	auto i = path.rfind('/');
	if (i == std::string::npos) return ".";
	return i == 0 ? "/" : path.substr(0, i);
}

std::string baseName(const std::string& path) {
	auto i = path.rfind('/');
	return i == std::string::npos ? path : path.substr(i + 1);
}

bool isExecutableFile(const std::string& path) {
	struct stat st {};
	return stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode) && access(path.c_str(), X_OK) == 0;
}

struct Layout {
	std::string tools; // <bundle>/Contents/Resources/tools
	std::string root;  // the checkout the bundle sits in: bin/qs and shims/ live there
};

// From the executable's real path, never argv[0]: the multicall form sets that
// to the tool's name on purpose. A binary outside a bundle (build/src/quickshell)
// has no tools and no shims; it still gets the runtime dir below.
//
// ponytail: root = the bundle's parent, which is the checkout as long as
// Quickshell.app is built in place. Moving the app to /Applications means
// moving shims/ (and a `qs` for PATH) into Contents/Resources first.
Layout locate() {
	char exe[PATH_MAX];
	auto size = static_cast<uint32_t>(sizeof(exe));
	if (_NSGetExecutablePath(exe, &size) != 0) return {};

	char real[PATH_MAX];
	if (realpath(exe, real) == nullptr) return {};

	auto macosDir = dirName(real);
	auto contents = dirName(macosDir);
	if (baseName(macosDir) != "MacOS" || baseName(contents) != "Contents") return {};

	return {.tools = contents + "/Resources/tools", .root = dirName(dirName(contents))};
}

bool listHas(const char* var, const std::string& entry) {
	const auto* value = getenv(var);
	if (value == nullptr) return false;
	auto padded = ":" + std::string(value) + ":";
	return padded.find(":" + entry + ":") != std::string::npos;
}

void prependToList(const char* var, const std::string& prefix) {
	const auto* value = getenv(var);
	auto joined = (value != nullptr && *value != '\0') ? prefix + ":" + value : prefix;
	setenv(var, joined.c_str(), 1);
}

// Mirrors the option check bin/qs made in bash: --path and --config are
// mutually exclusive in the parser, which does not care that one of them came
// from the environment, so a default QS_CONFIG_NAME must step aside for an
// explicit selection.
bool selectsConfig(int argc, char** argv) {
	for (auto i = 1; i < argc; i++) {
		std::string arg = argv[i];
		if (arg == "--config" || arg == "--path" || arg == "--manifest") return true;
		for (const auto* prefix: {"-c", "-p", "-m", "--config=", "--path=", "--manifest="}) {
			if (arg.rfind(prefix, 0) == 0) return true;
		}
	}
	return false;
}

// Whether `qs` should default QS_CONFIG_NAME to `name`. quickshell resolves a
// name to <config>/quickshell/<name>/shell.qml, but a shell.qml directly in
// <config>/quickshell -- the flat layout darwin-dotfiles keeps -- makes it
// skip that directory's subfolders, so a name there can only fail. That flat
// file is what the unnamed "default" config resolves to; leave the name unset
// and every `qs` and `qs ipc call` lands on it.
bool namedConfigExists(const char* name) {
	std::string base;
	if (const auto* xdg = getenv("XDG_CONFIG_HOME"); xdg != nullptr && *xdg != '\0') base = xdg;
	else if (const auto* home = getenv("HOME"); home != nullptr) base = std::string(home) + "/.config";
	else return false;
	base += "/quickshell";

	struct stat st {};
	if (stat((base + "/shell.qml").c_str(), &st) == 0 && S_ISREG(st.st_mode)) return false;
	return stat((base + "/" + name + "/shell.qml").c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

// quickshell's own subcommands win over a tool of the same name.
bool isBuiltin(const std::string& arg) {
	return arg == "log" || arg == "list" || arg == "kill" || arg == "ipc" || arg == "msg";
}

std::vector<std::string> listTools(const std::string& dir) {
	std::vector<std::string> names;
	if (auto* d = opendir(dir.c_str())) {
		while (auto* entry = readdir(d)) {
			std::string name = entry->d_name;
			if (name[0] != '.' && isExecutableFile(dir + "/" + name)) names.push_back(name);
		}
		closedir(d);
	}
	std::sort(names.begin(), names.end());
	return names;
}

[[noreturn]] void runTool(const std::string& path, char** argv) {
	// QS_TOOL_DRY_RUN prints what would run instead: tests/one-binary.sh
	// checks every dispatch route this way without running tools that
	// build, restart the shell or open windows.
	if (getenv("QS_TOOL_DRY_RUN") != nullptr) {
		printf("exec %s", path.c_str());
		for (auto** arg = argv; *arg != nullptr; arg++) printf(" %s", *arg);
		printf("\n");
		exit(0);
	}

	execv(path.c_str(), argv);
	fprintf(stderr, "qs: cannot exec %s: %s\n", path.c_str(), strerror(errno));
	exit(127);
}

} // namespace

void dispatch(int argc, char** argv) {
	auto layout = locate();

	// The Linux default is /run/user/$UID, which does not exist here; without
	// a runtime dir quickshell segfaults on startup and `ipc` finds nothing.
	const auto* runtimeDir = getenv("XDG_RUNTIME_DIR");
	if (runtimeDir == nullptr || *runtimeDir == '\0') {
		auto dir = "/tmp/quickshell-" + std::to_string(getuid());
		setenv("XDG_RUNTIME_DIR", dir.c_str(), 1);
		runtimeDir = getenv("XDG_RUNTIME_DIR");
	}
	mkdir(runtimeDir, 0700);

	if (!layout.tools.empty()) {
		// launchd and skhd hand down a minimal PATH (launchctl getenv PATH is
		// empty), so without this the shell finds neither yabai/jq nor its own
		// stand-ins. Tools first, bin/ next for `qs` itself; checked so the
		// qs -> tool -> qs chain does not grow it on every hop.
		if (!listHas("PATH", layout.tools)) {
			prependToList("PATH", layout.tools + ":" + layout.root + "/bin:/opt/homebrew/bin:/usr/local/bin");
		}

		auto shims = layout.root + "/shims";
		if (!listHas("QML2_IMPORT_PATH", shims)) prependToList("QML2_IMPORT_PATH", shims);

		if (argc > 1 && strcmp(argv[1], "--tools") == 0) {
			for (const auto& name: listTools(layout.tools)) printf("%s\n", name.c_str());
			exit(0);
		}

		auto self = baseName(argv[0]);
		if (self != "quickshell" && self != "qs" && isExecutableFile(layout.tools + "/" + self)) {
			runTool(layout.tools + "/" + self, argv);
		}

		if (argc > 1 && argv[1][0] != '-' && !isBuiltin(argv[1])
		    && isExecutableFile(layout.tools + "/" + argv[1]))
		{
			runTool(layout.tools + "/" + argv[1], argv + 1);
		}
	} else if (argc > 1 && strcmp(argv[1], "--tools") == 0) {
		fprintf(stderr, "qs: not running from Quickshell.app, so no tools (run bin/qs qs-build)\n");
		exit(1);
	}

	// From here on this process is quickshell itself. An explicit selection
	// wins over the default name: on the command line, or QS_CONFIG_PATH in
	// the environment, which is how a tool such as qs-ipc is pointed at an
	// instance that has no name (a test probe).
	if (selectsConfig(argc, argv)) {
		unsetenv("QS_CONFIG_NAME");
		unsetenv("QS_CONFIG_PATH");
	} else if (const auto* path = getenv("QS_CONFIG_PATH"); path != nullptr && *path != '\0') {
		unsetenv("QS_CONFIG_NAME");
	} else if (namedConfigExists(DEFAULT_CONFIG)) {
		setenv("QS_CONFIG_NAME", DEFAULT_CONFIG, 0);
	}
}

} // namespace qs::launch::macos
