library ftp;

{$IFDEF FPC}
{$mode delphi}{$H+}
{$ENDIF}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  DCConvertEncoding, FPCAdds, Classes, FtpFunc, FtpUtils, FtpConfDlg
{$IF DEFINED(UNIX)}
  , ssl_openssl_ver
{$ENDIF}
  , ssl_openssl
{$IF DEFINED(LINUX)}
  , ssl_gnutls
{$ENDIF}
  ;

exports
  FsInitW,
  FsFindFirstW,
  FsFindNextW,
  FsFindClose,
  FsExecuteFileW,
  RemoteThumbnailDirectoryStatusW,
  RemoteThumbnailDirectoryCapabilitiesW,
  FsRenMovFileW,
  FsGetFileW,
  FsGetPreviewBitmapW,
  FsPutFileW,
  FsDeleteFileW,
  FsMkDirW,
  FsRemoveDirW,
  FsSetTimeW,
  FsDisconnectW,
  FsSetCryptCallbackW,
  FsGetDefRootName,
  FsSetDefaultParams,
  FsStatusInfoW,
  FsGetBackgroundFlags,
  FsContentPluginUnloading,
  FsExtractCustomIconW,
  {
  FsNetworkGetSupportedProtocols,
  FsNetworkGetConnection,
  FsNetworkManageConnection,
  FsNetworkOpenConnection,
  }
  ExtensionInitialize;

{$R *.res}

begin
  Randomize;
end.
