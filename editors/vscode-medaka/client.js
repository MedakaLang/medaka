// Phase 34 — minimal VS Code language client.
// Spawns `medaka lsp` and connects to it via stdio.

const { workspace } = require('vscode');
const {
  LanguageClient,
  TransportKind,
} = require('vscode-languageclient/node');

let client;

function activate(_context) {
  const config = workspace.getConfiguration('medaka');
  const command = config.get('serverPath', 'medaka');

  const serverOptions = {
    run:   { command, args: ['lsp'], transport: TransportKind.stdio },
    debug: { command, args: ['lsp'], transport: TransportKind.stdio },
  };

  const clientOptions = {
    documentSelector: [{ scheme: 'file', language: 'medaka' }],
  };

  client = new LanguageClient(
    'medaka',
    'Medaka Language Server',
    serverOptions,
    clientOptions,
  );

  client.start();
}

function deactivate() {
  if (!client) return undefined;
  return client.stop();
}

module.exports = { activate, deactivate };
