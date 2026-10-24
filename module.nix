# drovr — hand tasks from your Claude Code session to headless Claude Code workers on
# cheaper Anthropic-compatible backends. Workers run --restricted with five file tools
# and an empty config, in a worktree of HEAD (public or allowlisted repos) or a
# prepared scratch folder. The answer comes back as one message.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.programs.drovr;

  drovr = pkgs.writeShellApplication {
    name = "drovr";
    runtimeInputs = [
      pkgs.jq
      pkgs.git
      pkgs.coreutils
      pkgs.gnused
      pkgs.util-linux # setsid
    ];
    text = builtins.readFile ./drovr.sh;
    # The script's own file-wide directive lands below this wrapper's header.
    excludeShellChecks = [ "SC2016" ];
  };

  # `claude-<name>`: a shortcut for `drovr claude <name>`, which reads the key at launch.
  aliases = lib.mapAttrsToList (
    name: _:
    pkgs.writeShellScriptBin "claude-${name}" ''exec ${lib.getExe drovr} claude ${lib.escapeShellArg name} "$@"''
  ) cfg.providers;

  # The config drovr reads; null options are left out.
  settings = {
    claude = lib.getExe cfg.claudePackage;
    inherit (cfg) defaultProvider allowedRepos stallSeconds nudge;
    providers = lib.mapAttrs (_: p: lib.filterAttrsRecursive (_: v: v != null) p) cfg.providers;
  }
  // lib.filterAttrs (_: v: v != null) { inherit (cfg) dailyBudget dailySoftLimit dailyWarn; };

  price = lib.types.submodule {
    options = {
      input = lib.mkOption {
        type = lib.types.number;
        description = "USD per 1M uncached input tokens.";
      };
      cachedInput = lib.mkOption {
        type = lib.types.nullOr lib.types.number;
        default = null;
        description = "USD per 1M cached input tokens; null charges them as input.";
      };
      output = lib.mkOption {
        type = lib.types.number;
        description = "USD per 1M output tokens.";
      };
    };
  };

  effort = lib.types.nullOr (
    lib.types.enum [
      "low"
      "medium"
      "high"
      "xhigh"
      "max"
    ]
  );

  # A model besides the provider's main one, for `drovr run --model`.
  extraModel = lib.types.submodule {
    options = {
      price = lib.mkOption {
        type = lib.types.nullOr price;
        default = null;
        description = "Token prices of this model. Without one its cost is not shown and it cannot carry a budget; it never falls back to the provider's price.";
      };
      effort = lib.mkOption {
        type = effort;
        default = null;
        description = "Default effort for this model; `drovr run --effort` overrides it.";
      };
    };
  };

  provider = lib.types.submodule {
    options = {
      baseUrl = lib.mkOption {
        type = lib.types.str;
        description = "Anthropic-compatible endpoint (ANTHROPIC_BASE_URL).";
        example = "https://api.deepseek.com/anthropic";
      };
      model = lib.mkOption {
        type = lib.types.str;
        description = "Main model id (ANTHROPIC_MODEL).";
        example = "deepseek-v4-pro";
      };
      smallModel = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Background-task model (ANTHROPIC_DEFAULT_HAIKU_MODEL); null keeps the endpoint's own mapping.";
      };
      keyFile = lib.mkOption {
        type = lib.types.str;
        description = "File holding the API key, read at launch (e.g. an agenix or sops-nix secret path).";
        example = "/run/agenix/deepseek-api-key";
      };
      price = lib.mkOption {
        type = lib.types.nullOr price;
        default = null;
        description = "Token prices for the cost column of `drovr list` and for budgets (0 for a free model).";
        example = {
          input = 0.66;
          cachedInput = 0.022;
          output = 1.98;
        };
      };
      effort = lib.mkOption {
        type = effort;
        default = null;
        description = "Default effort for the provider's main model; null leaves it to Claude Code.";
      };
      models = lib.mkOption {
        type = lib.types.attrsOf extraModel;
        default = { };
        description = "Other models of this provider, by model id, each with its own price and default effort.";
        example = {
          deepseek-flash = {
            price = {
              input = 0.3;
              cachedInput = 0.006;
              output = 1.2;
            };
            effort = "low";
          };
        };
      };
      authVar = lib.mkOption {
        type = lib.types.enum [
          "ANTHROPIC_AUTH_TOKEN"
          "ANTHROPIC_API_KEY"
        ];
        default = "ANTHROPIC_AUTH_TOKEN";
        description = "Variable the key goes into (ANTHROPIC_AUTH_TOKEN sends a Bearer header, ANTHROPIC_API_KEY sends x-api-key).";
      };
    };
  };
in
{
  options.programs.drovr = {
    enable = lib.mkEnableOption "drovr, headless Claude Code workers on Anthropic-compatible backends";

    claudePackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.claude-code;
      defaultText = lib.literalExpression "pkgs.claude-code";
      description = "Claude Code package the workers run.";
    };

    providers = lib.mkOption {
      type = lib.types.attrsOf provider;
      default = { };
      description = "Anthropic-compatible backends; each becomes a claude-<name> wrapper.";
    };

    defaultProvider = lib.mkOption {
      type = lib.types.str;
      default = "deepseek";
      description = "Provider used when `drovr run` gets no --via.";
    };

    # Default-deny: everything a worker reads is sent to its provider. Public repos
    # qualify without being listed.
    allowedRepos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Private repo roots (and everything under them) where drovr may start workers; each also needs a DROVR.md.";
    };

    stallSeconds = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 600;
      description = "Stop a worker after this many seconds without a single event (0: never). A model that is thinking still streams events, so silence means stuck.";
    };

    dailyBudget = lib.mkOption {
      type = lib.types.nullOr lib.types.number;
      default = null;
      description = "USD all workers together may spend per day; each call gets what is left. Needs a price on every provider used.";
      example = 5;
    };

    dailySoftLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.number;
      default = null;
      description = "USD per day after which drovr refuses new calls. Unlike dailyBudget it never stops a call that is running, so no turn is cut off halfway.";
      example = 5;
    };

    dailyWarn = lib.mkOption {
      type = lib.types.nullOr lib.types.number;
      default = null;
      description = "USD per day after which run, prompt, list and status (including the WezTerm helper) show a warning.";
      example = 2;
    };

    nudge = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "When an answer ends by announcing an action (\"Let me update the config:\") instead of taking it, resume the worker once with \"continue\".";
    };

    weztermHelper = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Install integrations/wezterm.lua as ~/.local/share/drovr/wezterm.lua for a status-bar summary.";
    };

    installSkill = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the drovr skill as ~/.claude/skills/drovr/SKILL.md.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.providers ? ${cfg.defaultProvider};
        message = "programs.drovr.defaultProvider '${cfg.defaultProvider}' is not in programs.drovr.providers";
      }
    ];

    home.packages = aliases ++ [ drovr ];

    xdg.configFile."drovr/config.json".text = builtins.toJSON settings;

    home.file.".claude/skills/drovr/SKILL.md" = lib.mkIf cfg.installSkill { source = ./SKILL.md; };
    home.file.".local/share/drovr/wezterm.lua" = lib.mkIf cfg.weztermHelper {
      source = ./integrations/wezterm.lua;
    };
  };
}
