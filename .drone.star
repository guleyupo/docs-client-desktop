def main(ctx):
    # Config

    environment = "desktop"

    # Version shown as latest in generated documentations
    # It's fine that this is out of date in version branches, usually just needs
    # adjustment in master/deployment_branch when a new version is added to site.yml
    latest_version = "2.10"
    default_branch = "master"

    # Current version branch (used to determine when changes are supposed to be pushed)
    # pushes to base_branch will trigger a build in deployment_branch but pushing
    # to fix-typo branch won't
    base_branch = latest_version

    # Version branches never deploy themselves, but instead trigger a deployment in deployment_branch
    # This must not be changed in version branches
    deployment_branch = default_branch
    pdf_branch = default_branch

    return cancelPreviousBuilds() + [
        checkStarlark(),
        build(ctx, environment, latest_version, deployment_branch, base_branch, pdf_branch),
        trigger(ctx, environment, latest_version, deployment_branch, base_branch, pdf_branch),
    ]

def checkStarlark():
    return {
        "kind": "pipeline",
        "type": "docker",
        "name": "check-starlark",
        "steps": [
            {
                "name": "format-check-starlark",
                "image": "owncloudci/bazel-buildifier",
                "pull": "always",
                "commands": [
                    "buildifier --mode=check .drone.star",
                ],
            },
            {
                "name": "show-diff",
                "image": "owncloudci/bazel-buildifier",
                "pull": "always",
                "commands": [
                    "buildifier --mode=fix .drone.star",
                    "git diff",
                ],
                "when": {
                    "status": [
                        "failure",
                    ],
                },
            },
        ],
        "depends_on": [],
        "trigger": {
            "ref": [
                "refs/pull/**",
            ],
        },
    }

def build(ctx, environment, latest_version, deployment_branch, base_branch, pdf_branch):
    return {
        "kind": "pipeline",
        "type": "docker",
        "name": "documentation",
        "platform": {
            "os": "linux",
            "arch": "amd64",
        },
        "steps": [
            {
                "name": "cache-restore",
                "pull": "always",
                "image": "plugins/s3-cache:1",
                "settings": {
                    "endpoint": from_secret("cache_s3_endpoint"),
                    "access_key": from_secret("cache_s3_access_key"),
                    "secret_key": from_secret("cache_s3_secret_key"),
                    "restore": "true",
                },
            },
            {
                "name": "docs-deps",
                "pull": "always",
                "image": "owncloudci/nodejs:16",
                "commands": [
                    "yarn install",
                ],
            },
            {
                "name": "docs-validate",
                "pull": "always",
                "image": "owncloudci/nodejs:16",
                "commands": [
                    "yarn validate --fetch",
                ],
            },
            {
                "name": "docs-build",
                "pull": "always",
                "image": "owncloudci/nodejs:16",
                "commands": [
                    "yarn antora --fetch --attribute format=html",
                ],
            },
            {
                "name": "docs-pdf",
                "pull": "always",
                "image": "owncloudci/asciidoctor:latest",
                "commands": [
                    "bin/makepdf -m",
                ],
            },
            {
                "name": "cache-rebuild",
                "pull": "always",
                "image": "plugins/s3-cache:1",
                "settings": {
                    "endpoint": from_secret("cache_s3_endpoint"),
                    "access_key": from_secret("cache_s3_access_key"),
                    "secret_key": from_secret("cache_s3_secret_key"),
                    "rebuild": "true",
                    "mount": [
                        "node_modules",
                    ],
                },
                "when": {
                    "event": [
                        "push",
                        "cron",
                    ],
                    "branch": [
                        deployment_branch,
                        base_branch,
                    ],
                },
            },
            {
                "name": "cache-flush",
                "pull": "always",
                "image": "plugins/s3-cache:1",
                "settings": {
                    "endpoint": from_secret("cache_s3_endpoint"),
                    "access_key": from_secret("cache_s3_access_key"),
                    "secret_key": from_secret("cache_s3_secret_key"),
                    "flush": "true",
                    "flush_age": "14",
                },
                "when": {
                    "event": [
                        "push",
                        "cron",
                    ],
                },
            },
            {
                "name": "upload-pdf",
                "pull": "always",
                "image": "plugins/s3-sync",
                "settings": {
                    "bucket": "uploads",
                    "endpoint": from_secret("docs_s3_server"),
                    "access_key": from_secret("docs_s3_access_key"),
                    "secret_key": from_secret("docs_s3_secret_key"),
                    "path_style": "true",
                    "source": "pdf_web/",
                    "target": "/pdf/%s" % environment,
                },
                "when": {
                    "event": [
                        "push",
                        "cron",
                    ],
                    "branch": [
                        pdf_branch,
                    ],
                },
            },
            {
                "name": "notify",
                "pull": "if-not-exists",
                "image": "plugins/slack",
                "settings": {
                    "webhook": from_secret("slack_webhook_private"),
                    "channel": "documentation",
                },
                "when": {
                    "event": [
                        "push",
                        "cron",
                    ],
                    "status": [
                        "failure",
                    ],
                },
            },
        ],
        "depends_on": [
            "check-starlark",
        ],
        "trigger": {
            "ref": {
                "include": [
                    "refs/heads/%s" % deployment_branch,
                    "refs/heads/%s" % pdf_branch,
                    "refs/tags/**",
                    "refs/pull/**",
                ],
            },
        },
    }

def trigger(ctx, environment, latest_version, deployment_branch, base_branch, pdf_branch):
    return {
        "kind": "pipeline",
        "type": "docker",
        "name": "trigger",
        "platform": {
            "os": "linux",
            "arch": "amd64",
        },
        "clone": {
            "disable": True,
        },
        "steps": [
            {
                "name": "trigger-docs",
                "pull": "always",
                "image": "plugins/downstream",
                "settings": {
                    "server": "https://drone.owncloud.com",
                    "token": from_secret("drone_token"),
                    "fork": "true",
                    "repositories": [
                        "owncloud/docs@master",
                    ],
                },
            },
        ],
        "depends_on": [
            "documentation",
        ],
        "trigger": {
            "ref": [
                "refs/heads/%s" % deployment_branch,
                "refs/heads/%s" % base_branch,
            ],
        },
    }

def from_secret(name):
    return {
        "from_secret": name,
    }

def cancelPreviousBuilds():
    return [{
        "kind": "pipeline",
        "type": "docker",
        "name": "cancel-previous-builds",
        "clone": {
            "disable": True,
        },
        "steps": [{
            "name": "cancel-previous-builds",
            "image": "owncloudci/drone-cancel-previous-builds",
            "settings": {
                "DRONE_TOKEN": {
                    "from_secret": "drone_token",
                },
            },
        }],
        "trigger": {
            "ref": [
                "refs/pull/**",
            ],
        },
    }]
