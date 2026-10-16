// capacitor.config.ts
// 当前文件：Capacitor iOS 打包配置。
//
// 桌面端仍由 Electron 承载（electron/main.cjs），本配置只在构建 iOS 包时生效。
// 构建产物沿用 Vite 的 dist/，因此 iOS 端与 Web 端共用同一套前端代码。

import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  // 与 Electron 的 build.appId 保持一致，iOS 上即 Bundle Identifier。
  appId: 'top.izuna.foliamajor',
  appName: 'Folia',
  webDir: 'dist',
  // 与前端首屏底色一致，避免 WebView 首帧出现白闪。
  backgroundColor: '#09090b',
  ios: {
    // 全屏沉浸：歌词/visualizer 铺满整块屏幕，安全区交给 CSS 的 env(safe-area-inset-*)
    // 处理（src/index.css），不让 WebView 自己加内边距，否则刘海机横屏时四周会留黑边。
    contentInset: 'never',
    preferredContentMode: 'mobile',
    scrollEnabled: true,
  },
};

export default config;
