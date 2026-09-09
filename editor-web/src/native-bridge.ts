export type NativeBridge = { postMessage(message: unknown): void };

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        clairEditor?: NativeBridge;
        clairDiffViewer?: NativeBridge;
      };
    };
  }
}
