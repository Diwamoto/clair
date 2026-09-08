import type { Metadata, Viewport } from 'next';
import './globals.css';

export const metadata: Metadata = {
  metadataBase: new URL('https://clair-interaction-lab.daiki-work-0118.chatgpt.site'),
  title: 'Clair',
  description: 'ソース編集とターミナル作業に集中できるProjectワークスペース。',
  icons: { icon: '/icon.png' },
  openGraph: {
    title: 'Clair',
    description: 'ソース編集とターミナル作業に集中できるProjectワークスペース。',
    type: 'website',
    images: [{ url: '/og.png', width: 1200, height: 630, alt: 'Clairのエディタとターミナルの操作モック' }],
  },
  twitter: {
    card: 'summary_large_image',
    title: 'Clair',
    description: 'ソース編集とターミナル作業に集中できるProjectワークスペース。',
    images: ['/og.png'],
  },
};

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  viewportFit: 'cover',
  themeColor: '#282c34',
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="ja">
      <body>{children}</body>
    </html>
  );
}
