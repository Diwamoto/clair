'use client';

import { useCallback, useEffect, useRef, useState } from 'react';

import { canvasScreens } from './canvas-screens';

type CanvasScreen = (typeof canvasScreens)[number];

type Interaction = {
  label: string;
  action: () => void;
};

const initialScreen = canvasScreens[0];

function screenById(id: string) {
  return canvasScreens.find((screen) => screen.id === id) ?? initialScreen;
}

function leafElements(root: HTMLElement, predicate: (text: string) => boolean) {
  return Array.from(root.querySelectorAll<HTMLElement>('*')).filter((element) => (
    element.children.length === 0 && predicate(element.textContent?.trim() ?? '')
  ));
}

function rawScreenRoot(frame: HTMLElement) {
  return frame.querySelector<HTMLElement>(':scope > .canvas-content > div');
}

function useRawScreenInteractions(
  frameRef: React.RefObject<HTMLDivElement | null>,
  screen: CanvasScreen,
  navigate: (id: string) => void,
  report: (message: string) => void,
) {
  useEffect(() => {
    const frame = frameRef.current;
    const rawRoot = frame ? rawScreenRoot(frame) : null;
    if (!rawRoot) return;

    const cleanups: Array<() => void> = [];
    const attach = (element: HTMLElement, interaction: Interaction, editable = false) => {
      const original = {
        role: element.getAttribute('role'),
        tabIndex: element.getAttribute('tabindex'),
        ariaLabel: element.getAttribute('aria-label'),
        contentEditable: element.getAttribute('contenteditable'),
        cursor: element.style.cursor,
      };
      element.setAttribute('role', editable ? 'textbox' : 'button');
      element.setAttribute('aria-label', interaction.label);
      if (!editable) element.setAttribute('tabindex', '0');
      if (editable) element.setAttribute('contenteditable', 'true');
      element.style.cursor = 'pointer';

      const onClick = () => interaction.action();
      const onKeyDown = (event: KeyboardEvent) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          interaction.action();
        }
      };
      element.addEventListener('click', onClick);
      if (!editable) element.addEventListener('keydown', onKeyDown);
      cleanups.push(() => {
        element.removeEventListener('click', onClick);
        element.removeEventListener('keydown', onKeyDown);
        if (original.role === null) element.removeAttribute('role');
        else element.setAttribute('role', original.role);
        if (original.tabIndex === null) element.removeAttribute('tabindex');
        else element.setAttribute('tabindex', original.tabIndex);
        if (original.ariaLabel === null) element.removeAttribute('aria-label');
        else element.setAttribute('aria-label', original.ariaLabel);
        if (original.contentEditable === null) element.removeAttribute('contenteditable');
        else element.setAttribute('contenteditable', original.contentEditable);
        element.style.cursor = original.cursor;
      });
    };
    const onExactText = (text: string, interaction: Interaction) => {
      for (const element of leafElements(rawRoot, (value) => value === text)) attach(element, interaction);
    };
    const onText = (fragment: string, interaction: Interaction) => {
      for (const element of leafElements(rawRoot, (value) => value.includes(fragment))) attach(element, interaction);
    };
    const makeEditable = (text: string, label: string) => {
      const element = leafElements(rawRoot, (value) => value === text)[0];
      if (!element) return;
      const input = document.createElement('input');
      input.type = 'text';
      input.value = element.textContent?.trim() ?? '';
      input.setAttribute('aria-label', label);
      input.style.cssText = (element.getAttribute('style') ?? '') + '; background: transparent; border: 0; outline: 0; padding: 0; width: 100px; min-width: 0; font: inherit; color: inherit;';
      element.replaceWith(input);
      const onInput = () => report(label + ': ' + input.value);
      input.addEventListener('input', onInput);
      cleanups.push(() => {
        input.removeEventListener('input', onInput);
        if (input.isConnected) input.replaceWith(element);
      });
    };

    if (screen.id === 'Main') {
      const titleActions = Array.from(rawRoot.querySelectorAll<HTMLElement>('.act')).slice(0, 2);
      if (titleActions[0]) attach(titleActions[0], { label: 'コマンドパレットを開く', action: () => navigate('CommandPalette') });
      if (titleActions[1]) attach(titleActions[1], { label: '設定を開く', action: () => navigate('Settings') });
      onExactText('ファイル、シンボル', { label: '検索を開く', action: () => navigate('Search') });

      const sidebarActions = Array.from(rawRoot.querySelectorAll<HTMLElement>('.act')).slice(-6);
      const sidebarInteractions: Interaction[] = [
        { label: 'ファイルツリーを開く', action: () => report('ファイルツリーを表示中') },
        { label: '検索を開く', action: () => navigate('Search') },
        { label: 'ソース管理を開く', action: () => navigate('SourceControl') },
        { label: '実行とデバッグを開く', action: () => navigate('Debug') },
        { label: 'アクティビティを開く', action: () => navigate('Activity') },
        { label: 'セッションを開く', action: () => navigate('SessionRail') },
      ];
      sidebarActions.forEach((element, index) => {
        if (element) attach(element, sidebarInteractions[index]);
      });
      onText('Apply this change?', { label: 'ターミナルの入力を確認', action: () => report('ターミナルの確認待ちです') });
    }

    if (screen.id === 'Search') {
      onExactText('esc', { label: '検索を閉じる', action: () => navigate('Main') });
      makeEditable('Workspace', '検索語');
      onText('@State private var', { label: '検索結果を開く', action: () => navigate('Main') });
      onText('Workspace View(workspace: workspace)', { label: '検索結果を開く', action: () => navigate('Main') });
    }

    if (screen.id === 'SourceControl') {
      onText('merge commitで採用', { label: 'マージグラフを開く', action: () => navigate('MergeGraph') });
      onText('ProjectWorkspace.swift', { label: 'ProjectWorkspace.swiftの差分を確認', action: () => report('ProjectWorkspace.swift の差分を表示中') });
    }

    if (screen.id === 'Activity') {
      onExactText('アクティビティを絞り込む', { label: 'アクティビティを絞り込む', action: () => report('アクティビティの絞り込み') });
      onText('変更を適用する前に承認', { label: '承認リクエストを確認', action: () => report('承認リクエストを確認中') });
      onText('Agentにメッセージ', { label: 'Agentを追加', action: () => navigate('AddAgent') });
      onText('ターミナルを開く', { label: 'ターミナルを開く', action: () => navigate('Main') });
    }

    if (screen.id === 'Debug') {
      onExactText('clair', { label: 'clair Projectを開く', action: () => navigate('Main') });
      onText('セッションを開始', { label: 'デバッグセッションを再開', action: () => report('デバッグセッションを再開しました') });
    }

    if (screen.id === 'Settings') {
      onExactText('モバイル', { label: 'モバイル確認を開く', action: () => navigate('MobileOverview') });
      onExactText('ターミナル', { label: 'ターミナル設定を表示', action: () => report('ターミナル設定を表示中') });
      onExactText('エディタ', { label: 'エディタ設定を表示', action: () => report('エディタ設定を表示中') });
      onText('前回のレイアウトを復元', { label: 'レイアウト復元を切り替え', action: () => report('レイアウト復元を切り替えました') });
    }

    if (screen.id === 'AddAgent') {
      onExactText('Agentを起動 ↗', { label: 'Agentを起動', action: () => navigate('SessionRail') });
      onExactText('ターミナル', { label: 'ターミナル起動を選択', action: () => report('ターミナル起動を選択しました') });
      onExactText('アクティビティ', { label: 'アクティビティ起動を選択', action: () => report('アクティビティ起動を選択しました') });
    }

    if (screen.id === 'CommandPalette') {
      onExactText('ファイルへ移動', { label: 'ファイルへ移動', action: () => navigate('Search') });
      onExactText('ペインを右に分割', { label: 'ペインを右に分割', action: () => navigate('Main') });
      onExactText('ペインを下に分割', { label: 'ペインを下に分割', action: () => navigate('Main') });
      onExactText('ペインを閉じる', { label: 'ペインを閉じる', action: () => navigate('Main') });
    }

    if (screen.id === 'SessionRail') {
      onText('次の注意へ', { label: '次の注意へ移動', action: () => navigate('Activity') });
      onExactText('Agentを起動', { label: 'Agentを追加', action: () => navigate('AddAgent') });
      onExactText('移動', { label: 'セッションをワークスペースへ移動', action: () => navigate('Main') });
      onExactText('再起動', { label: 'セッションを再起動', action: () => report('セッションを再起動しました') });
    }

    if (screen.id === 'MobileOverview') {
      onExactText('ターミナルを開く', { label: 'ターミナルを開く', action: () => navigate('SessionRail') });
      onExactText('アクティビティ', { label: 'アクティビティを開く', action: () => navigate('Activity') });
    }

    if (screen.id === 'DebugAgent') {
      onExactText('適用してテスト', { label: '修正を適用してテスト', action: () => navigate('Activity') });
      onExactText('却下', { label: '修正を却下', action: () => report('修正案を却下しました') });
    }

    if (screen.id === 'MergeGraph') {
      onExactText('clair', { label: 'clair Projectへ戻る', action: () => navigate('Main') });
    }

    return () => cleanups.reverse().forEach((cleanup) => cleanup());
  }, [frameRef, navigate, report, screen.id]);
}

export default function Home() {
  const [activeId, setActiveId] = useState(initialScreen.id);
  const frameRef = useRef<HTMLDivElement>(null);
  const feedbackRef = useRef<HTMLSpanElement>(null);
  const feedbackTimeoutRef = useRef<number | null>(null);
  const active = screenById(activeId);

  const report = useCallback((message: string) => {
    const feedback = feedbackRef.current;
    if (!feedback) return;
    feedback.textContent = message;
    if (feedbackTimeoutRef.current !== null) window.clearTimeout(feedbackTimeoutRef.current);
    feedbackTimeoutRef.current = window.setTimeout(() => {
      if (feedbackRef.current === feedback) feedback.textContent = '';
      feedbackTimeoutRef.current = null;
    }, 2400);
  }, []);
  const navigate = useCallback((id: string) => {
    setActiveId(id);
    if (feedbackTimeoutRef.current !== null) {
      window.clearTimeout(feedbackTimeoutRef.current);
      feedbackTimeoutRef.current = null;
    }
    if (feedbackRef.current) feedbackRef.current.textContent = '';
  }, []);

  useRawScreenInteractions(frameRef, active, navigate, report);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      const modifier = event.metaKey || event.ctrlKey;
      if (modifier && event.key.toLowerCase() === 'k') {
        event.preventDefault();
        navigate('CommandPalette');
      } else if (modifier && event.shiftKey && event.key.toLowerCase() === 'f') {
        event.preventDefault();
        navigate('Search');
      } else if (modifier && event.shiftKey && event.key.toLowerCase() === 'd') {
        event.preventDefault();
        navigate('Debug');
      } else if (event.key === 'Escape' && active.id !== 'Main') {
        navigate('Main');
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [active.id, navigate]);

  return (
    <div className="screen-shell">
      <div className="screen-stage">
        <div
          className="screen-frame"
          ref={frameRef}
          style={{ width: active.width, height: active.height }}
        >
          <style dangerouslySetInnerHTML={{ __html: active.css }} />
          <div className="canvas-content" dangerouslySetInnerHTML={{ __html: active.html }} />
        </div>
        <span ref={feedbackRef} className="screen-interaction-feedback" aria-live="polite" />
      </div>
    </div>
  );
}
