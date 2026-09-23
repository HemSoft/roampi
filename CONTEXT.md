# RoamPi

RoamPi connects a mobile user to Pi sessions and approved actions on user-authorized remote machines.

## Language

**Machine configuration**:
The home-host `.roampi` document that defines participating machines, global navigation, projects, and final project overrides.
_Avoid_: Global config, home config

**Project contribution**:
A repository's `.roampi` document, whose pages, data, actions, and jobs remain inside that project's namespace.
_Avoid_: Project override, plugin

**Effective configuration**:
The validated result of deterministic machine and project configuration merging.
_Avoid_: Combined config, runtime config

**Action trust identity**:
A digest binding approval to one source file, action or command-backed data source, resolved SSH host, username and port, working directory, and canonical configuration hash.
_Avoid_: Approval ID, action hash

**Last-known-good configuration**:
The most recent effective configuration retained when a later complete update is invalid.
_Avoid_: Cache, fallback config

**Fixed interface**:
Native Settings and configuration-recovery routes that remote configuration cannot replace or hide.
_Avoid_: System page, reserved page
