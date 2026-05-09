{ lib }:

{
  # Like lib.types.deferredModule, but each user definition is wrapped as
  # `{ config = def; }` before being injected as a module — the same trick
  # submoduleWith does via shorthandOnlyDefinesConfig.
  #
  # Without this, an option whose value is itself a deferredModule (e.g.
  # `forest.common.config = { ... }: { ... }`) trips the module system: the
  # body `{ config = <function> }` parses `config` as the reserved
  # options-to-set key (which must be an attrset), not as the option named
  # `config`, so the lambda fails type-checking. Wrapping moves the
  # reserved-key collision out one layer so the user-side top level is
  # unambiguously a config block — keys there are option names, and a nested
  # `config` flows through to its inner deferredModule as either a function
  # or an attrset. Definitions stay separate so mkDefault/mkForce priorities
  # merge with downstream definitions normally.
  shorthandDeferredModule = lib.types.mkOptionType {
    name = "shorthandDeferredModule";
    description = "deferred module (top-level keys define options)";
    check = lib.isAttrs;
    # Wrap each value as `{ config = <user attrs>; }` and hand off to
    # deferredModule's merge so we inherit its file-location attribution
    # (`"<file>, via option <path>"`) and any future improvements.
    merge = loc: defs:
      lib.types.deferredModule.merge loc (lib.map (def: def // {
        value = { config = def.value; };
      }) defs);
    emptyValue.value = {};
  };
}
