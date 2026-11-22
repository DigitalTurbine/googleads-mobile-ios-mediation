// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "GADMAdapterFyberAppOpenAd.h"

#import <IASDKCore/IASDKCore.h>
// IAAppOpenAd is a Swift API; the umbrella header doesn't include the generated interface.
#import <IASDKCore/IASDKCore-Swift.h>

#import <stdatomic.h>

#import "GADMAdapterFyberConstants.h"
#import "GADMAdapterFyberUtils.h"

@interface GADMAdapterFyberAppOpenAd () <GADMediationAppOpenAd, IAAppOpenAdDelegate>
@end

@implementation GADMAdapterFyberAppOpenAd {
  /// Ad configuration for the ad to be loaded.
  GADMediationAppOpenAdConfiguration *_adConfiguration;

  /// The completion handler to call when an ad loads successfully or fails.
  GADMediationAppOpenLoadCompletionHandler _loadCompletionHandler;

  /// The ad event delegate to forward ad rendering events to the Google Mobile Ads SDK.
  __weak id<GADMediationAppOpenAdEventDelegate> _delegate;

  /// DT Exchange app open ad. It owns the interstitial stack (ad spot, fullscreen unit controller,
  /// MRAID and video content controllers) and applies the App Open rules: the spot must be an App
  /// Open spot, the ad is one-shot, and it can't be shown once expired.
  IAAppOpenAd *_appOpenAd;
}

- (instancetype)initWithAdConfiguration:(GADMediationAppOpenAdConfiguration *)adConfiguration {
  self = [super init];
  if (self) {
    _adConfiguration = adConfiguration;
  }
  return self;
}

- (void)loadAppOpenAdWithCompletionHandler:
    (GADMediationAppOpenLoadCompletionHandler)completionHandler {
  __block atomic_flag adLoadHandlerCalled = ATOMIC_FLAG_INIT;
  __block GADMediationAppOpenLoadCompletionHandler originalAdLoadHandler = [completionHandler copy];

  // Ensure the original completion handler is only called once, and is deallocated once called.
  _loadCompletionHandler = ^id<GADMediationAppOpenAdEventDelegate>(
      id<GADMediationAppOpenAd> appOpenAd, NSError *error) {
    if (atomic_flag_test_and_set(&adLoadHandlerCalled)) {
      return nil;
    }

    id<GADMediationAppOpenAdEventDelegate> delegate = nil;
    if (originalAdLoadHandler) {
      delegate = originalAdLoadHandler(appOpenAd, error);
    }

    originalAdLoadHandler = nil;
    return delegate;
  };

  GADMAdapterFyberAppOpenAd *__weak weakSelf = self;
  GADMAdapterFyberInitializeWithAppId(
      _adConfiguration.credentials.settings[GADMAdapterFyberApplicationID],
      ^(BOOL success, NSError *_Nullable error) {
        GADMAdapterFyberAppOpenAd *strongSelf = weakSelf;
        if (!strongSelf) {
          return;
        }

        if (success) {
          // DTExchange requires to set COPPA after every successful initialization.
          GADMAdapterFyberSetCOPPA();
        }

        if (error) {
          GADMAdapterFyberLog(@"Failed to initialize DT Exchange SDK: %@",
                              error.localizedDescription);
          strongSelf->_loadCompletionHandler(nil, error);
          return;
        }

        [strongSelf loadAppOpenAd];
      });
}

- (void)loadAppOpenAd {
  NSString *bidResponse = _adConfiguration.bidResponse;
  IAAdRequest *request;
  if (!bidResponse) {
    // Waterfall flow
    NSString *spotID = _adConfiguration.credentials.settings[GADMAdapterFyberSpotID];
    if (!spotID.length) {
      NSError *error = GADMAdapterFyberErrorWithCodeAndDescription(
          GADMAdapterFyberErrorInvalidServerParameters, @"Missing or Invalid Spot ID.");
      GADMAdapterFyberLog(@"%@", error.localizedDescription);
      _loadCompletionHandler(nil, error);
      return;
    }

    request = GADMAdapterFyberBuildRequestWithSpotIDAndAdConfiguration(spotID, _adConfiguration);
  } else {
    // Bidding flow: the spot comes from the markup.
    request = GADMAdapterFyberBuildRequestWithAdConfiguration(_adConfiguration);
  }

  IASDKCore.sharedInstance.mediationType = [[IAMediationAdMob alloc] init];

  GADMAdapterFyberAppOpenAd *__weak weakSelf = self;
  void (^completion)(IAAppOpenAd *_Nullable, NSError *_Nullable) =
      ^(IAAppOpenAd *_Nullable appOpenAd, NSError *_Nullable error) {
        GADMAdapterFyberAppOpenAd *strongSelf = weakSelf;
        if (!strongSelf) {
          return;
        }

        if (!appOpenAd) {
          GADMAdapterFyberLog(@"Failed to load app open ad: %@", error.localizedDescription);
          strongSelf->_loadCompletionHandler(nil, error);
          return;
        }

        strongSelf->_appOpenAd = appOpenAd;
        appOpenAd.delegate = strongSelf;
        strongSelf->_delegate = strongSelf->_loadCompletionHandler(strongSelf, nil);
      };

  if (bidResponse) {
    [IAAppOpenAd loadWithRequest:request
                          markup:bidResponse
                   watermarkData:_adConfiguration.watermark
                      completion:completion];
  } else {
    [IAAppOpenAd loadWithRequest:request completion:completion];
  }
}

#pragma mark - GADMediationAppOpenAd

- (void)presentFromViewController:(nonnull UIViewController *)viewController {
  // IAAppOpenAd checks that the ad wasn't shown yet, hasn't expired and that the view controller
  // is in a window; a failed check comes back through -appOpenAd:didFailToPresentWithError:.
  [_appOpenAd showFromViewController:viewController animated:YES];
}

#pragma mark - IAAppOpenAdDelegate

- (void)appOpenAdDidRecordImpression:(nonnull IAAppOpenAd *)ad {
  [_delegate reportImpression];
}

- (void)appOpenAdDidClick:(nonnull IAAppOpenAd *)ad {
  [_delegate reportClick];
}

- (void)appOpenAdWillPresent:(nonnull IAAppOpenAd *)ad {
  [_delegate willPresentFullScreenView];
}

- (void)appOpenAdDidPresent:(nonnull IAAppOpenAd *)ad {
  // Google Mobile Ads SDK doesn't have a matching event.
}

- (void)appOpenAdWillDismiss:(nonnull IAAppOpenAd *)ad {
  // GADMediationAdEventDelegate's willDismissFullScreenView is deprecated in favor of
  // didDismissFullScreenView.
}

- (void)appOpenAdDidDismiss:(nonnull IAAppOpenAd *)ad {
  [_delegate didDismissFullScreenView];
}

- (void)appOpenAd:(nonnull IAAppOpenAd *)ad didFailToPresentWithError:(nonnull NSError *)error {
  GADMAdapterFyberLog(@"Failed to present app open ad: %@", error.localizedDescription);
  [_delegate didFailToPresentWithError:error];
}

- (void)appOpenAdDidExpire:(nonnull IAAppOpenAd *)ad {
  // Not a presentation failure on its own: a later -presentFromViewController: fails with
  // IAAppOpenAdErrorExpired.
  GADMAdapterFyberLog(@"App open ad expired.");
}

@end
