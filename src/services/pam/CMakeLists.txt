# subprocess.cpp isolates the PAM conversation in a forked child so abort()
# can just kill it (PAM itself has no cancel API) -- see the comment on
# PamConversation. That's unsafe on Apple: fork() without exec() in a process
# that links AppKit/libdispatch/XPC (which pam_opendirectory.so talks to) can
# leave the child deadlocked or dead before it ever calls back. conversation.cpp
# runs PAM in-process there instead; see its Apple branch.
set(PAM_SOURCES qml.cpp conversation.cpp ipc.cpp)
if (NOT APPLE)
	list(APPEND PAM_SOURCES subprocess.cpp)
endif()

qt_add_library(quickshell-service-pam STATIC
	${PAM_SOURCES}
)

qt_add_qml_module(quickshell-service-pam
	URI Quickshell.Services.Pam
	VERSION 0.1
	DEPENDENCIES QtQml
)

install_qml_module(quickshell-service-pam)

target_link_libraries(quickshell-service-pam PRIVATE
	Qt::Qml pam ${PAM_LIBRARIES}
	Qt::Quick # pch
)

qs_module_pch(quickshell-service-pam)

target_link_libraries(quickshell PRIVATE quickshell-service-pamplugin)
