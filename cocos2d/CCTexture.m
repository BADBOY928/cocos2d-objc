/*
 * cocos2d for iPhone: http://www.cocos2d-iphone.org
 *
 * Copyright (c) 2014 Cocos2D Authors
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */


#import "Platforms/CCGL.h"
#import "Platforms/CCNS.h"

#import "CCTexture.h"
#import "ccConfig.h"
#import "ccMacros.h"
#import "CCDeviceInfo.h"
#import "CCTexturePVR.h"
#import "CCShader.h"
#import "CCDirector.h"
#import "CCRenderDispatch.h"
#import "CCImage.h"

#import "Support/ccUtils.h"
#import "Support/CCFileUtils.h"

#import "CCTexture_Private.h"
#import "CCTextureCache.h"
#import "CCSpriteFrame.h"

#if __CC_METAL_SUPPORTED_AND_ENABLED
#import "CCMetalSupport_Private.h"
#endif


NSString * const CCTextureOptionGenerateMipmaps = @"CCTextureOptionGenerateMipmaps";
NSString * const CCTextureOptionMinificationFilter = @"CCTextureOptionMinificationFilter";
NSString * const CCTextureOptionMagnificationFilter = @"CCTextureOptionMagnificationFilter";
NSString * const CCTextureOptionMipmapFilter = @"CCTextureOptionMipmapFilter";
NSString * const CCTextureOptionAddressModeX = @"CCTextureOptionAddressModeX";
NSString * const CCTextureOptionAddressModeY = @"CCTextureOptionAddressModeY";


//CLASS IMPLEMENTATIONS:

// This class implements what will hopefully be a temporary replacement
// for the retainCount trick used to figure out which cached objects are safe to purge.
@implementation CCProxy
{
    id _target;
}

- (id)initWithTarget:(id)target
{
    if ((self = [super init]))
    {
        _target = target;
    }
    
    return(self);
}

// Forward class checks for assertions.
-(BOOL)isKindOfClass:(Class)aClass {return [_target isKindOfClass:aClass];}

// Make concrete implementations for CCTexture methods commonly called at runtime.
-(GLuint)name {return [(CCTexture *)_target name];}
-(CGFloat)contentScale {return [(CCTexture *)_target contentScale];}
-(CGSize)contentSize {return [_target contentSize];}
-(NSUInteger)pixelWidth {return [_target pixelWidth];}
-(NSUInteger)pixelHeight {return [_target pixelHeight];}
-(BOOL)hasPremultipliedAlpha {return [_target hasPremultipliedAlpha];}
-(CCSpriteFrame *)spriteFrame {return [_target spriteFrame];}

// Make concrete implementations for CCSpriteFrame methods commonly called at runtime.
-(CGRect)rect {return [_target rect];}
-(CGPoint)offset {return [(CCSpriteFrame *)_target offset];}
-(BOOL)rotated {return [_target rotated];}
-(CGSize)originalSize {return [_target originalSize];}
-(CCTexture *)texture {return [_target texture];}

// Let the rest fall back to a slow forwarded path.
- (id)forwardingTargetForSelector:(SEL)aSelector
{
//    CCLOGINFO(@"Forwarding selector [%@ %@]", NSStringFromClass([_target class]), NSStringFromSelector(aSelector));
//		CCLOGINFO(@"If there are many of these calls, we should add concrete forwarding methods. (TODO remove logging before release)");
    return(_target);
}

- (void)dealloc
{
		CCLOGINFO(@"Proxy for %p deallocated.", _target);
}

@end


#pragma mark -
#pragma mark CCTexture2D - Main

@implementation CCTexture
{
	BOOL _premultipliedAlpha;
	BOOL _hasMipmaps;
	
	CCProxy __weak *_proxy;
    
    BOOL _antialiased;
}

static NSDictionary *DEFAULT_OPTIONS = nil;

static CCTexture *CCTextureNone = nil;

+(void)initialize
{
	// +initialize may be called due to loading a subclass.
	if(self != [CCTexture class]) return;
    
    DEFAULT_OPTIONS = @{
        CCTextureOptionGenerateMipmaps: @(NO),
        CCTextureOptionMinificationFilter: @(CCTextureFilterLinear),
        CCTextureOptionMagnificationFilter: @(CCTextureFilterLinear),
        CCTextureOptionMipmapFilter: @(CCTextureFilterMipmapNone),
        CCTextureOptionAddressModeX: @(CCTextureAddressModeClampToEdge),
        CCTextureOptionAddressModeY: @(CCTextureAddressModeClampToEdge),
    };
	
	CCTextureNone = [self alloc];
	CCTextureNone->_name = 0;
	CCTextureNone->_contentScale = 1.0;
	
#if __CC_METAL_SUPPORTED_AND_ENABLED
	if([CCConfiguration sharedConfiguration].graphicsAPI == CCGraphicsAPIMetal){
		CCMetalContext *context = [CCMetalContext currentContext];
		NSAssert(context, @"Metal context is nil.");
		
		CCTextureNone->_metalSampler = [context.device newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
		
		MTLTextureDescriptor *textureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
		CCTextureNone->_metalTexture = [context.device newTextureWithDescriptor:textureDesc];
	}
#endif
}

+(instancetype)none
{
	return CCTextureNone;
}

+ (id) textureWithFile:(NSString*)file
{
    return [[CCTextureCache sharedTextureCache] addImage:file];
}

static NSDictionary *
NormalizeOptions(NSDictionary *options)
{
    if(options == nil || options == DEFAULT_OPTIONS){
        return DEFAULT_OPTIONS;
    } else {
        // Merge the default values with the user values.
        NSMutableDictionary *opts = [DEFAULT_OPTIONS mutableCopy];
        [opts addEntriesFromDictionary:options];
        
        return opts;
    }
}

-(instancetype)initWithImage:(CCImage *)image options:(NSDictionary *)options
{
    options = NormalizeOptions(options);
    
    CCDeviceInfo *info = [CCDeviceInfo sharedDeviceInfo];
	NSAssert(info.graphicsAPI != CCGraphicsAPIInvalid, @"Graphics API not configured.");
	
    NSUInteger maxTextureSize = [info maxTextureSize];
    CGSize sizeInPixels = image.sizeInPixels;
    
    if(sizeInPixels.width > maxTextureSize || sizeInPixels.height > maxTextureSize){
        CCLOGWARN(@"cocos2d: Error: Image (%d x %d) is bigger than the maximum supported texture size %d",
            (int)sizeInPixels.width, (int)sizeInPixels.height, (int)maxTextureSize
        );
        
        return nil;
    }
    
    BOOL isPOT = CCSizeIsPOT(sizeInPixels);
    if(!isPOT && !info.supportsNPOT){
        CCLOGWARN(@"cocos2d: Error: This device requires power of two sized textures.");
        
        return nil;
    }
    
	if((self = [super init])) {
#if __CC_METAL_SUPPORTED_AND_ENABLED
        // TODO
#endif
		CCRenderDispatch(NO, ^{
            CCGL_DEBUG_PUSH_GROUP_MARKER("CCTexture: Init");
            
            glGenTextures(1, &_name);
            glBindTexture(GL_TEXTURE_2D, _name);
            
            BOOL genMipmaps = [options[CCTextureOptionGenerateMipmaps] boolValue];
            
            // Set up texture filtering mode.
            CCTextureFilter minFilter = [options[CCTextureOptionMinificationFilter] unsignedIntegerValue];
            CCTextureFilter magFilter = [options[CCTextureOptionMagnificationFilter] unsignedIntegerValue];
            CCTextureFilter mipFilter = [options[CCTextureOptionMipmapFilter] unsignedIntegerValue];
            
            NSAssert(minFilter != CCTextureFilterMipmapNone, @"CCTextureFilterMipmapNone can only be used with CCTextureOptionMipmapFilter.");
            NSAssert(magFilter != CCTextureFilterMipmapNone, @"CCTextureFilterMipmapNone can only be used with CCTextureOptionMipmapFilter.");
            NSAssert(mipFilter == CCTextureFilterMipmapNone || genMipmaps, @"CCTextureOptionMipmapFilter must be CCTextureFilterMipmapNone unless CCTextureOptionGenerateMipmaps is YES");
            
            static const GLenum FILTERS[3][3] = {
                {GL_LINEAR, GL_LINEAR, GL_LINEAR}, // Invalid enum, fall back to linear.
                {GL_NEAREST, GL_NEAREST_MIPMAP_NEAREST, GL_NEAREST_MIPMAP_LINEAR}, // nearest
                {GL_LINEAR, GL_LINEAR_MIPMAP_NEAREST, GL_LINEAR_MIPMAP_LINEAR}, // linear
            };
            
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, FILTERS[minFilter][mipFilter]);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, FILTERS[magFilter][CCTextureFilterMipmapNone]);
            
            // Set up texture addressing mode.
            CCTextureAddressMode addressX = [options[CCTextureOptionAddressModeX] unsignedIntegerValue];
            CCTextureAddressMode addressY = [options[CCTextureOptionAddressModeY] unsignedIntegerValue];
            
            static const GLenum ADDRESSING[] = {
                GL_CLAMP_TO_EDGE,
                GL_REPEAT,
                GL_MIRRORED_REPEAT,
            };
            
            NSAssert(addressX == CCTextureAddressModeClampToEdge || isPOT, @"Only CCTextureAddressModeClampToEdge can be used with non power of two sized textures.");
            NSAssert(addressY == CCTextureAddressModeClampToEdge || isPOT, @"Only CCTextureAddressModeClampToEdge can be used with non power of two sized textures.");
            
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, ADDRESSING[addressX]);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, ADDRESSING[addressY]);

            // Specify OpenGL texture image
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (GLsizei)sizeInPixels.width, (GLsizei)sizeInPixels.height, 0, GL_RGBA, GL_UNSIGNED_BYTE, image.pixelData.bytes);
            
            // Generate mipmaps.
            if(genMipmaps){
                glGenerateMipmap(GL_TEXTURE_2D);
            }
            
            CCGL_DEBUG_POP_GROUP_MARKER();
		});
        
        _sizeInPixels = sizeInPixels;
        _contentScale = image.contentScale;
        _contentSize = image.contentSize;
    }
    
	return self;
}

// -------------------------------------------------------------

- (BOOL)hasProxy
{
    @synchronized(self)
    {
        // NSLog(@"hasProxy: %p", self);
        return(_proxy != nil);
    }
}

- (CCProxy *)proxy
{
    @synchronized(self)
    {
        __strong CCProxy *proxy = _proxy;

        if (_proxy == nil)
        {
            proxy = [[CCProxy alloc] initWithTarget:self];
            _proxy = proxy;
        }
    
        return(proxy);
    }
}

// -------------------------------------------------------------

- (void) dealloc
{
	CCLOGINFO(@"cocos2d: deallocing %@", self);
	
	GLuint name = _name;
	if(name){
		CCRenderDispatch(YES, ^{
			CCGL_DEBUG_PUSH_GROUP_MARKER("CCTexture: Dealloc");
			glDeleteTextures(1, &name);
			CCGL_DEBUG_POP_GROUP_MARKER();
		});
	}
}

- (NSString*) description
{
	return [NSString stringWithFormat:@"<%@ = %p | Name = %i | Dimensions = %lux%lu pixels >",
        [self class], self, _name, (unsigned long)_sizeInPixels.width, (unsigned long)_sizeInPixels.height];
}

-(CCSpriteFrame*)spriteFrame
{
	CGRect rectInPixels = {CGPointZero, _sizeInPixels};
	return [CCSpriteFrame frameWithTexture:(CCTexture *)self.proxy rectInPixels:rectInPixels rotated:NO offset:CGPointZero originalSize:_sizeInPixels];
}

@end


@implementation CCTexture(Deprecated)

- (void) setAntialiased:(BOOL)antialiased
{
	if(_antialiased != antialiased){
		CCRenderDispatch(NO, ^{
#if __CC_METAL_SUPPORTED_AND_ENABLED
			if([CCConfiguration sharedConfiguration].graphicsAPI == CCGraphicsAPIMetal){
				CCMetalContext *context = [CCMetalContext currentContext];
				
				MTLSamplerDescriptor *samplerDesc = [MTLSamplerDescriptor new];
				samplerDesc.minFilter = samplerDesc.magFilter = (antialiased ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest);
				samplerDesc.mipFilter = (_hasMipmaps ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterNotMipmapped);
				samplerDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
				samplerDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
				
				_metalSampler = [context.device newSamplerStateWithDescriptor:samplerDesc];
			} else
#endif
			{
				CCGL_DEBUG_PUSH_GROUP_MARKER("CCTexture: Set Alias Texture Parameters");
				
				glBindTexture(GL_TEXTURE_2D, _name);
				
				if(_hasMipmaps){
					glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, antialiased ? GL_NEAREST_MIPMAP_NEAREST : GL_NEAREST_MIPMAP_NEAREST);
				} else {
					glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, antialiased ? GL_LINEAR : GL_NEAREST);
				}
				glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, antialiased ? GL_LINEAR : GL_NEAREST);
				
				CCGL_DEBUG_POP_GROUP_MARKER();
				CC_CHECK_GL_ERROR_DEBUG();
			}
		});
		
		_antialiased = antialiased;
	}
}

@end

//#pragma mark -
//#pragma mark CCTexture2D - PVRSupport
//
//@implementation CCTexture (PVRSupport)
//
//// By default PVR images are treated as if they have the alpha channel premultiplied
//static BOOL _PVRHaveAlphaPremultiplied = YES;
//
//-(id) initWithPVRFile: (NSString*) relPath
//{
//	CGFloat contentScale;
//	NSString *fullpath = [[CCFileUtils sharedFileUtils] fullPathForFilename:relPath contentScale:&contentScale];
//
//	if( (self = [super init]) ) {
//		CCTexturePVR *pvr = [[CCTexturePVR alloc] initWithContentsOfFile:fullpath];
//		if( pvr ) {
//			pvr.retainName = YES;	// don't dealloc texture on release
//
//			_name = pvr.name;	// texture id
//			_maxS = 1;			// only POT texture are supported
//			_maxT = 1;
//			_width = pvr.width;
//			_height = pvr.height;
//			_sizeInPixels = CGSizeMake(_width, _height);
//			_premultipliedAlpha = (pvr.forcePremultipliedAlpha) ? pvr.hasPremultipliedAlpha : _PVRHaveAlphaPremultiplied;
//			_format = pvr.format;
//
//			_hasMipmaps = ( pvr.numberOfMipmaps > 1  );
//
//		} else {
//
//			CCLOG(@"cocos2d: Couldn't load PVR image: %@", relPath);
//			return nil;
//		}
//		_contentScale = contentScale;
//	}
//	return self;
//}
//
//+(void) PVRImagesHavePremultipliedAlpha:(BOOL)haveAlphaPremultiplied
//{
//	_PVRHaveAlphaPremultiplied = haveAlphaPremultiplied;
//}
//@end
//
//#pragma mark -
//#pragma mark CCTexture2D - Drawing
//
//#pragma mark -
//#pragma mark CCTexture2D - GLFilter
//
////
//// Use to apply MIN/MAG filter
////
//@implementation CCTexture (GLFilter)
//
//-(void) generateMipmap
//{
//	if(!_hasMipmaps){
//		CCRenderDispatch(NO, ^{
//#if __CC_METAL_SUPPORTED_AND_ENABLED
//			if([CCConfiguration sharedConfiguration].graphicsAPI == CCGraphicsAPIMetal){
//				CCMetalContext *context = [CCMetalContext currentContext];
//				
//				// Create a new blank texture.
//				MTLPixelFormat metalFormat = MetalPixelFormats[_format];
//				MTLTextureDescriptor *textureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:metalFormat width:_width height:_height mipmapped:YES];
//				id<MTLTexture> newTexture = [context.device newTextureWithDescriptor:textureDesc];
//				
//				// Set up a command buffer for the blit operations.
//				id<MTLCommandBuffer> blitCommands = [context.commandQueue commandBuffer];
//				id<MTLBlitCommandEncoder> blitter = [blitCommands blitCommandEncoder];
//				
//				// Copy in level 0.
//				MTLOrigin origin = MTLOriginMake(0, 0, 0);
//				MTLSize size = MTLSizeMake(_width, _height, 1);
//				[blitter
//					copyFromTexture:_metalTexture sourceSlice:0 sourceLevel:0 sourceOrigin:origin sourceSize:size
//					toTexture:newTexture destinationSlice:0 destinationLevel:0 destinationOrigin:origin
//				];
//				
//				// Generate mipmaps and commit.
//				[blitter generateMipmapsForTexture:newTexture];
//				[blitter endEncoding];
//				[blitCommands commit];
//				
//				// Update sampler and texture.
//				MTLSamplerDescriptor *samplerDesc = [MTLSamplerDescriptor new];
//				samplerDesc.minFilter = samplerDesc.magFilter = (_antialiased ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest);
//				samplerDesc.mipFilter = MTLSamplerMipFilterNearest; // TODO trillinear?
//				samplerDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
//				samplerDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
//				
//				_metalSampler = [context.device newSamplerStateWithDescriptor:samplerDesc];
//				NSLog(@"Generate mipmaps. Replacing %p with %p.", _metalTexture, newTexture);
//				_metalTexture = newTexture;
//			} else
//#endif
//			{
//				CCGL_DEBUG_PUSH_GROUP_MARKER("CCTexture: Generate Mipmap");
//				
//				NSAssert( _width == CCNextPOT(_width) && _height == CCNextPOT(_height), @"Mimpap texture only works in POT textures");
//				glBindTexture(GL_TEXTURE_2D, _name);
//				glGenerateMipmap(GL_TEXTURE_2D);
//				
//				// Update the minification filter.
//				glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, _antialiased ? GL_LINEAR_MIPMAP_NEAREST : GL_NEAREST_MIPMAP_NEAREST);
//				
//				CCGL_DEBUG_POP_GROUP_MARKER();
//			}
//		});
//	}
//	
//	_hasMipmaps = YES;
//}
//
//-(void) setTexParameters: (ccTexParams*) texParams
//{
//	CCRenderDispatch(NO, ^{
//		CCGL_DEBUG_PUSH_GROUP_MARKER("CCTexture: Set Texture Parameters");
//		
//		NSAssert([CCDeviceInfo sharedDeviceInfo].graphicsAPI == CCGraphicsAPIGL, @"Not implemented for Metal.");
//		NSAssert( (_width == CCNextPOT(_width) && _height == CCNextPOT(_height)) ||
//					(texParams->wrapS == GL_CLAMP_TO_EDGE && texParams->wrapT == GL_CLAMP_TO_EDGE),
//				@"GL_CLAMP_TO_EDGE should be used in NPOT dimensions");
//
//		glBindTexture(GL_TEXTURE_2D, _name );
//		glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, texParams->minFilter );
//		glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, texParams->magFilter );
//		glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, texParams->wrapS );
//		glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, texParams->wrapT );
//		
//		CCGL_DEBUG_POP_GROUP_MARKER();
//		CC_CHECK_GL_ERROR_DEBUG();
//	});
//}
//
//@end
