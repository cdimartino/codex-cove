import type * as vscode from "vscode";

import { buildStatusText } from "./sessionMarkers";
import type { SessionMarker, StatusSnapshot } from "./models";

export class StatusPresenter {
  private readonly channel: vscode.OutputChannel;
  private readonly statusBar: vscode.StatusBarItem;

  constructor(channel: vscode.OutputChannel, statusBar: vscode.StatusBarItem) {
    this.channel = channel;
    this.statusBar = statusBar;
  }

  render(snapshot: StatusSnapshot): void {
    const text = buildStatusText(snapshot);
    this.statusBar.text = `Cove: ${text}`;
    this.statusBar.tooltip = text;
    this.statusBar.show();
    this.channel.clear();
    this.channel.appendLine(text);
  }

  showMarker(marker: SessionMarker): void {
    this.channel.appendLine(`registered ${marker.markerId}`);
  }
}
