'use client';

import { useMemo, useRef, useState } from 'react';

import styles from './SourceSearchPanel.module.css';

export type SourceFileRecord = {
  name: string;
  path: string;
  content: string;
};

export type SourceSearchMatch = {
  fileName: string;
  path: string;
  line: number;
  content: string;
};

type SearchOptions = {
  caseSensitive: boolean;
  wholeWord: boolean;
  useRegex: boolean;
};

type SearchFileGroup = {
  fileName: string;
  path: string;
  matches: SourceSearchMatch[];
};

type SearchDirectoryGroup = {
  path: string;
  matches: number;
  files: SearchFileGroup[];
};

const defaultOptions: SearchOptions = {
  caseSensitive: false,
  wholeWord: false,
  useRegex: false,
};

function makeSearchExpression(query: string, options: SearchOptions) {
  if (!query) return null;
  const escaped = options.useRegex
    ? query
    : query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const pattern = options.wholeWord ? `\\b(?:${escaped})\\b` : escaped;
  return new RegExp(pattern, options.caseSensitive ? 'g' : 'gi');
}

function groupMatches(matches: SourceSearchMatch[]): SearchDirectoryGroup[] {
  const directories = new Map<string, Map<string, SourceSearchMatch[]>>();

  for (const match of matches) {
    const separator = match.path.lastIndexOf('/');
    const directory = separator >= 0 ? match.path.slice(0, separator) : '.';
    const files = directories.get(directory) ?? new Map<string, SourceSearchMatch[]>();
    const fileMatches = files.get(match.path) ?? [];
    fileMatches.push(match);
    files.set(match.path, fileMatches);
    directories.set(directory, files);
  }

  return Array.from(directories, ([path, files]) => {
    const groupedFiles = Array.from(files, ([filePath, fileMatches]) => ({
      fileName: fileMatches[0].fileName,
      path: filePath,
      matches: fileMatches,
    }));
    return {
      path,
      files: groupedFiles,
      matches: groupedFiles.reduce((total, file) => total + file.matches.length, 0),
    };
  });
}

function SearchHighlight({ content, query, options }: { content: string; query: string; options: SearchOptions }) {
  let expression: RegExp | null;
  try {
    expression = makeSearchExpression(query, options);
  } catch {
    return content;
  }
  if (!expression) return content;

  const pieces: React.ReactNode[] = [];
  let cursor = 0;
  let match: RegExpExecArray | null;

  while ((match = expression.exec(content)) !== null) {
    if (match.index > cursor) pieces.push(content.slice(cursor, match.index));
    pieces.push(<mark key={`${match.index}-${pieces.length}`}>{match[0]}</mark>);
    cursor = match.index + match[0].length;
    if (match[0].length === 0) break;
  }
  if (cursor < content.length) pieces.push(content.slice(cursor));

  return pieces.length ? <>{pieces}</> : content;
}

export function SourceSearchPanel({
  projectName,
  files,
  onOpenMatch,
}: {
  projectName: string;
  files: SourceFileRecord[];
  onOpenMatch: (match: SourceSearchMatch) => void;
}) {
  const [query, setQuery] = useState('Workspace');
  const [options, setOptions] = useState<SearchOptions>(defaultOptions);
  const [collapsedDirectories, setCollapsedDirectories] = useState<Set<string>>(new Set());
  const [collapsedFiles, setCollapsedFiles] = useState<Set<string>>(new Set());
  const [activeMatchKey, setActiveMatchKey] = useState<string | null>(null);
  const [copiedMatchKey, setCopiedMatchKey] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const search = useMemo(() => {
    if (!query.trim()) return { matches: [] as SourceSearchMatch[], error: null as string | null };

    let expression: RegExp;
    try {
      expression = makeSearchExpression(query, options) as RegExp;
    } catch {
      return { matches: [] as SourceSearchMatch[], error: '正規表現が正しくありません' };
    }

    const matches: SourceSearchMatch[] = [];
    for (const file of files) {
      file.content.split('\n').forEach((content, index) => {
        expression.lastIndex = 0;
        if (expression.test(content)) {
          matches.push({ fileName: file.name, path: file.path, line: index + 1, content });
        }
      });
    }
    return { matches, error: null as string | null };
  }, [files, options, query]);

  const directories = useMemo(() => groupMatches(search.matches), [search.matches]);
  const fileCount = directories.reduce((total, directory) => total + directory.files.length, 0);

  const toggleSetValue = (
    setter: React.Dispatch<React.SetStateAction<Set<string>>>,
    key: string,
  ) => {
    setter((current) => {
      const next = new Set(current);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };

  const toggleOption = (key: keyof SearchOptions) => {
    setOptions((current) => ({ ...current, [key]: !current[key] }));
    setCollapsedDirectories(new Set());
    setCollapsedFiles(new Set());
    setActiveMatchKey(null);
  };

  const activateMatch = (match: SourceSearchMatch) => {
    const key = `${match.path}:${match.line}`;
    setActiveMatchKey(key);
    onOpenMatch(match);
  };

  const copyMatchPath = async (match: SourceSearchMatch) => {
    const key = `${match.path}:${match.line}`;
    try {
      await navigator.clipboard.writeText(`${match.path}:L${match.line}`);
      setCopiedMatchKey(key);
      window.setTimeout(() => setCopiedMatchKey((current) => current === key ? null : current), 1500);
    } catch {
      setCopiedMatchKey(null);
    }
  };

  return (
    <aside className={styles.panel} aria-label="ソース検索">
      <div className={styles.heading}>
        <span>検索</span>
        <kbd>⌘⇧F</kbd>
      </div>

      <div className={styles.searchHeader}>
        <div className={styles.inputRow}>
          <span className={styles.searchGlyph} aria-hidden="true" />
          <input
            ref={inputRef}
            autoFocus
            type="text"
            value={query}
            onChange={(event) => {
              setQuery(event.target.value);
              setCollapsedDirectories(new Set());
              setCollapsedFiles(new Set());
              setActiveMatchKey(null);
            }}
            placeholder="フォルダ内を検索…"
            aria-label="ソースファイルを検索"
            spellCheck={false}
          />
          {query && (
            <button
              type="button"
              className={styles.clearButton}
              onClick={() => {
                setQuery('');
                inputRef.current?.focus();
              }}
              aria-label="ソース検索をクリア"
              title="クリア"
            >
              ×
            </button>
          )}
        </div>

        <div className={styles.searchMeta} aria-live="polite">
          <span>
            {search.error ? (
              <em>{search.error}</em>
            ) : query && search.matches.length ? (
              <><strong>{search.matches.length}</strong>件の結果 · <strong>{fileCount}</strong>ファイル</>
            ) : query ? (
              '結果はありません'
            ) : (
              '検索語を入力'
            )}
          </span>
          <div className={styles.options}>
            {([
              ['caseSensitive', 'Aa', '大文字と小文字を区別'],
              ['wholeWord', 'ab', '単語単位'],
              ['useRegex', '.*', '正規表現を使用'],
            ] as const).map(([key, label, title]) => (
              <button
                key={key}
                type="button"
                className={options[key] ? styles.optionActive : ''}
                onClick={() => toggleOption(key)}
                aria-pressed={options[key]}
                title={title}
              >
                {label}
              </button>
            ))}
          </div>
        </div>
      </div>

      <div className={styles.results}>
        {!query && (
          <div className={styles.emptyState}>
            <span className={styles.largeSearchGlyph} aria-hidden="true" />
            <p>このProjectを検索するには入力してください</p>
          </div>
        )}

        {directories.map((directory) => {
          const directoryCollapsed = collapsedDirectories.has(directory.path);
          return (
            <section className={styles.directory} key={directory.path}>
              <button
                type="button"
                className={styles.directoryRow}
                onClick={() => toggleSetValue(setCollapsedDirectories, directory.path)}
                aria-expanded={!directoryCollapsed}
              >
                <span className={`${styles.chevron} ${directoryCollapsed ? '' : styles.chevronOpen}`}>›</span>
                <span className={styles.folderGlyph} aria-hidden="true" />
                <span className={styles.directoryPath}>
                  <i>{projectName}/</i>{directory.path === '.' ? 'root' : directory.path}
                </span>
                <span className={`${styles.matchBadge} ${styles.matchBadgeDim}`}>{directory.matches}</span>
              </button>

              {!directoryCollapsed && directory.files.map((file) => {
                const fileCollapsed = collapsedFiles.has(file.path);
                return (
                  <div className={styles.fileGroup} key={file.path}>
                    <button
                      type="button"
                      className={styles.fileRow}
                      onClick={() => toggleSetValue(setCollapsedFiles, file.path)}
                      aria-expanded={!fileCollapsed}
                    >
                      <span className={`${styles.chevron} ${fileCollapsed ? '' : styles.chevronOpen}`}>›</span>
                      <span className={styles.fileGlyph} aria-hidden="true" />
                      <span className={styles.fileName}>{file.fileName}</span>
                      <span className={styles.matchBadge}>{file.matches.length}</span>
                    </button>

                    {!fileCollapsed && file.matches.map((match) => {
                      const key = `${match.path}:${match.line}`;
                      const active = activeMatchKey === key;
                      const copied = copiedMatchKey === key;
                      return (
                        <div
                          key={key}
                          className={`${styles.matchRow} ${active ? styles.matchRowActive : ''}`}
                          role="button"
                          tabIndex={0}
                          onClick={() => activateMatch(match)}
                          onKeyDown={(event) => {
                            if (event.key === 'Enter' || event.key === ' ') {
                              event.preventDefault();
                              activateMatch(match);
                            }
                          }}
                        >
                          <span className={styles.lineNumber}>{match.line}</span>
                          <code>
                            <SearchHighlight content={match.content.trimStart()} query={query} options={options} />
                          </code>
                          <button
                            type="button"
                            className={`${styles.copyButton} ${copied ? styles.copyButtonDone : ''}`}
                            onClick={(event) => {
                              event.stopPropagation();
                              void copyMatchPath(match);
                            }}
                            title={`${match.path}:L${match.line}をコピー`}
                            aria-label={`${match.path}の${match.line}行目をコピー`}
                          >
                            {copied ? '✓' : <span className={styles.copyGlyph} aria-hidden="true" />}
                          </button>
                        </div>
                      );
                    })}
                  </div>
                );
              })}
            </section>
          );
        })}
      </div>
    </aside>
  );
}
