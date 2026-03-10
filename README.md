# Shortcut Exporter

Exports stories, epics, documents and files from [Shortcut](https://shortcut.com) to local markdown files. Runs inside a Docker container.

## Setup

1. Copy the environment file and add your API token:

```bash
cp .env.example .env
```

Get your token at https://app.shortcut.com/settings/account/api-tokens

2. Build the Docker image:

```bash
docker compose build
```

## Usage

### Export a specific epic (with its stories and files)

```bash
docker compose run --rm exporter --epic 12345
```

### Export all stories from a team

```bash
docker compose run --rm exporter --team "Engineering"
```

### Export a specific document by ID

```bash
docker compose run --rm exporter --doc "12345678-9012-3456-7890-123456789012"
```

### Export all documents

```bash
docker compose run --rm exporter --docs
```

### Export everything

```bash
docker compose run --rm exporter --all
```

### Combine options

```bash
docker compose run --rm exporter --epic 42 --docs
```

### Custom output directory

```bash
docker compose run --rm exporter --epic 42 --output /export/my-project
```

## Output Structure

```
export/
├── epics/
│   ├── 123-Epic-Name.md
│   └── 123-Epic-Name-comments.md
├── stories/
│   └── 456-Story-Title.md
├── documents/
│   └── abcd1234-Doc-Title.md
└── files/
    └── 789-filename.md
```

Each markdown file contains structured metadata (as tables) and the original content.

## API Reference

This tool uses the [Shortcut REST API v3](https://developer.shortcut.com/api/rest/v3). Rate limiting is handled automatically (200 requests/minute).
