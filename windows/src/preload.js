'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('ds', {
  getState: () => ipcRenderer.invoke('ds:get-state'),
  action: (type, payload) => ipcRenderer.invoke('ds:action', { type, payload }),
  onState: (callback) => {
    const listener = (_event, state) => callback(state);
    ipcRenderer.on('ds:state', listener);
    return () => ipcRenderer.removeListener('ds:state', listener);
  },
  resize: (height) => ipcRenderer.send('ds:resize', height),
});
