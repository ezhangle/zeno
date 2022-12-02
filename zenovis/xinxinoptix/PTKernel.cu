#include <optix.h>
#include <cuda/random.h>
#include <cuda/helpers.h>
#include <sutil/vec_math.h>

#include "optixPathTracer.h"
#include "TraceStuff.h"
#include "DisneyBSDF.h"

#include "volume.h"
#include "zxxglslvec.h"

// #include <optix.h>
// #include <vector_types.h>
// #include <cuda/random.h>
// #include <cuda/helpers.h>

#include <nanovdb/NanoVDB.h>
#include <nanovdb/util/Ray.h>
#include <nanovdb/util/HDDA.h>
// #include <nanovdb/util/Stencils.h>
#include <nanovdb/util/SampleFromVoxels.h>

extern "C" {
__constant__ Params params;

}
//------------------------------------------------------------------------------
//
//
//
//------------------------------------------------------------------------------
static __inline__ __device__
vec3 RRTAndODTFit(vec3 v)
{
    vec3 a = v * (v + 0.0245786f) - 0.000090537f;
    vec3 b = v * (0.983729f * v + 0.4329510f) + 0.238081f;
    return a / b;
}
static __inline__ __device__
vec3 ACESFitted(vec3 color, float gamma)
{
//    const mat3x3 ACESInputMat = mat3x3
//        (
//            0.59719, 0.35458, 0.04823,
//            0.07600, 0.90834, 0.01566,
//            0.02840, 0.13383, 0.83777
//        );
//    mat3x3 ACESOutputMat = mat3x3
//    (
//        1.60475, -0.53108, -0.07367,
//        -0.10208,  1.10813, -0.00605,
//        -0.00327, -0.07276,  1.07602
//    );
    vec3 v1 = vec3(0.59719, 0.35458, 0.04823);
    vec3 v2 = vec3(0.07600, 0.90834, 0.01566);
    vec3 v3 = vec3(0.02840, 0.13383, 0.83777);
    color = vec3(dot(color, v1), dot(color, v2), dot(color, v3));

    // Apply RRT and ODT
    color = RRTAndODTFit(color);

    v1 = vec3(1.60475, -0.53108, -0.07367);
    v2 = vec3(-0.10208,  1.10813, -0.00605);
    v3 = vec3(-0.00327, -0.07276,  1.07602);
    color = vec3(dot(color, v1), dot(color, v2), dot(color, v3));

    // Clamp to [0, 1]
    color = clamp(color, 0.0, 1.0);

    color = pow(color, vec3(1. / gamma));

    return color;
}
extern "C" __global__ void __raygen__rg()
{
    const int    w   = params.width;
    const int    h   = params.height;
    //const float3 eye = params.eye;
    const uint3  idx = optixGetLaunchIndex();
    const int    subframe_index = params.subframe_index;
    const CameraInfo cam = params.cam;

    unsigned int seed = tea<4>( idx.y*w + idx.x, subframe_index );
    float focalPlaneDistance = cam.focalPlaneDistance>0.01? cam.focalPlaneDistance : 0.01;
    float aperture = clamp(cam.aperture,0.0f,100.0f);
    aperture/=10;

    float3 result = make_float3( 0.0f );
    int i = params.samples_per_launch;
    do
    {
        // The center of each pixel is at fraction (0.5,0.5)
        float2 subpixel_jitter = sobolRnd2(seed);

        float2 d = 2.0f * make_float2(
                ( static_cast<float>( idx.x ) + subpixel_jitter.x ) / static_cast<float>( w ),
                ( static_cast<float>( idx.y ) + subpixel_jitter.y ) / static_cast<float>( h )
                ) - 1.0f;
        //float3 ray_direction = normalize(cam.right * d.x + cam.up * d.y + cam.front);
        float2 r01 = sobolRnd2(seed);
        
        float r0 = r01.x * 2.0f* M_PIf;
        float r1 = r01.y * aperture * aperture;
        r1 = sqrt(r1);
        float3 ray_origin    = cam.eye + r1 * ( cosf(r0)* cam.right + sinf(r0)* cam.up);
        float3 ray_direction = cam.eye + focalPlaneDistance *(cam.right * d.x + cam.up * d.y + cam.front) - ray_origin;

        RadiancePRD prd;
        prd.emitted      = make_float3(0.f);
        prd.radiance     = make_float3(0.f);
        prd.attenuation  = make_float3(1.f);
        prd.attenuation2 = make_float3(1.f);
        prd.prob         = 1.0f;
        prd.prob2        = 1.0f;
        prd.countEmitted = true;
        prd.done         = false;
        prd.seed         = seed;
        prd.opacity      = 0;
        prd.flags        = 0;
        prd.is_inside    = false;
        prd.maxDistance  = 1e16f;
        prd.medium       = DisneyBSDF::PhaseFunctions::vacuum;

        prd.depth = 0;
        prd.diffDepth = 0;
        prd.isSS = false;
        prd.direction = ray_direction;
        prd.curMatIdx = 0;
        prd.is_test_ray = false;
        for(;;)
        {
            //prd.attenuation2 = prd.attenuation;

            traceRadiance(
                    params.handle,
                    ray_origin,
                    ray_direction,
                    1e-5f,  // tmin       // TODO: smarter offset
                    prd.maxDistance,  // tmax
                    &prd );
            
            vec3 radiance = vec3(prd.radiance);
            vec3 oldradiance = radiance;
            RadiancePRD shadow_prd;
            shadow_prd.shadowAttanuation = make_float3(1.0f, 1.0f, 1.0f);
            shadow_prd.nonThinTransHit = prd.nonThinTransHit;
            traceOcclusion(params.handle, prd.LP, prd.Ldir,
                           1e-5f, // tmin
                           1e16f, // tmax,
                           &shadow_prd);

            prd.attenuation2 = prd.attenuation;

            // if (prd.depth > 1) {

            //     const uint3    launch_index = optixGetLaunchIndex();
            //     const unsigned int image_index  = launch_index.y * params.width + launch_index.x;
            //     params.frame_buffer[ image_index ] = make_color(prd.attenuation2);
            //     return;
            // }

            radiance = radiance * prd.Lweight * vec3(shadow_prd.shadowAttanuation);
            radiance = radiance + vec3(prd.emission);
            
            prd.radiance = float3(mix(oldradiance, radiance, prd.CH));

            //result += prd.emitted;
            if(prd.countEmitted==false || prd.depth>0) {
                result += prd.radiance * prd.attenuation2/(prd.prob2 + 1e-5);
                //result += prd.emission * prd.attenuation2;
                prd.emission = make_float3(0);
            }
            if(prd.countEmitted==true && prd.depth>0){
                prd.done = true;
            }
            if( prd.done ){
                prd.attenuation2 = prd.attenuation;
                break;
            }
            if(prd.depth>8){
                //float RRprob = clamp(length(prd.attenuation)/1.732f,0.01f,0.9f);
                float RRprob = clamp(length(prd.attenuation),0.1, 0.95);
                if(rnd(prd.seed) > RRprob || prd.depth>16){
                    prd.done=true;

                }
                prd.attenuation = prd.attenuation / (RRprob + 1e-5);
            }
            if(prd.countEmitted == true)
                prd.passed = true;

            ray_origin    = prd.origin;
            ray_direction = prd.direction;
            //prd.attenuation2 = prd.attenuation;
            // if(prd.passed == false)
            //     ++depth;        
            //}else{
                //prd.passed = false;
            //}
        }
    }
    while( --i );

    const uint3    launch_index = optixGetLaunchIndex();
    const unsigned int image_index  = launch_index.y * params.width + launch_index.x;
    float3         accum_color  = result / static_cast<float>( params.samples_per_launch );

    if( subframe_index > 0 )
    {
        const float                 a = 1.0f / static_cast<float>( subframe_index+1 );
        const float3 accum_color_prev = make_float3( params.accum_buffer[ image_index ]);
        accum_color = lerp( accum_color_prev, accum_color, a );
    }
    /*if (launch_index.x == 0) {*/
        /*printf("%p\n", params.accum_buffer);*/
        /*printf("%p\n", params.frame_buffer);*/
    /*}*/
    params.accum_buffer[ image_index ] = make_float4( accum_color, 1.0f);
    vec3 aecs_fitted = ACESFitted(vec3(accum_color), 2.2);
    float3 out_color = accum_color;
    params.frame_buffer[ image_index ] = make_color ( out_color );
}

#define _INF_F            __int_as_float(0x7f800000)

extern "C" __global__ void __miss__radiance()
{
    const int ix = optixGetLaunchIndex().x;
    const int iy = optixGetLaunchIndex().y;

    vec3 sunLightDir = vec3(
            params.sunLightDirX,
            params.sunLightDirY,
            params.sunLightDirZ
            );
    MissData* rt_data  = reinterpret_cast<MissData*>( optixGetSbtDataPointer() );
    RadiancePRD* prd = getPRD();
    prd->attenuation2 = prd->attenuation;
    prd->passed = false;
    prd->countEmitted = false;
    prd->CH = 0.0;
    if(prd->medium != DisneyBSDF::PhaseFunctions::isotropic){
        prd->radiance = envSky(
            normalize(prd->direction),
            sunLightDir,
            make_float3(0., 0., 1.),
            40, // be careful
            .45,
            15.,
            1.030725 * 0.3,
            params.elapsedTime
        );
        prd->done      = true;
        return;
    }
    prd->attenuation *= DisneyBSDF::Transmission(prd->extinction,optixGetRayTmax());
    prd->attenuation2 *= DisneyBSDF::Transmission(prd->extinction,optixGetRayTmax());
    prd->origin += prd->direction * optixGetRayTmax();
    prd->direction = DisneyBSDF::SampleScatterDirection(prd->seed);
    float tmpPDF;
    prd->maxDistance = DisneyBSDF::SampleDistance(prd->seed,prd->scatterStep,prd->extinction,tmpPDF);
    prd->scatterPDF= tmpPDF;
    prd->depth++;

    if (prd->depth == 1) {
        prd->attenuation = make_float3(0.0);
    }

    if(length(prd->attenuation)<1e-7f){
        prd->done = true;
    }
}

extern "C" __global__ void __miss__occlusion()
{
    auto *prd = getPRD();
    prd->transmittanceVDB = 1.0f;
    //optixSetPayload_0( __float_as_uint( 1.0f ) ); // report transmittance

    const int ix = optixGetLaunchIndex().x;
    const int iy = optixGetLaunchIndex().y;

    // if (ix == 0 && iy == 0) {
    //     printf("__miss__occlusion \n");
    // }
}

extern "C" __global__ void __closesthit__occlusion()
{
    setPayloadOcclusion( true );

    auto *prd = getPRD();
    prd->transmittanceVDB = 0.0;


    const int ix = optixGetLaunchIndex().x;
    const int iy = optixGetLaunchIndex().y;

    // if (ix == 0 && iy == 0) {
    //     printf("__closesthit__occlusion \n");
    // }

    if (ix == 0 && iy == 0) {
        printf("__closesthit__occlusion thread x=%d y=%d shadowAttanuation=%f \n", ix, iy, prd->shadowAttanuation);
    }
}

//
// Masked
//

static __forceinline__ __device__ void traceRadianceMasked(
	OptixTraversableHandle handle,
	float3                 ray_origin,
	float3                 ray_direction,
	float                  tmin,
	float                  tmax,
	uint8_t                mask,
	RadiancePRD           *prd)
{
    unsigned int u0, u1;
    packPointer( prd, u0, u1 );

    optixTrace(
            handle,
            ray_origin, ray_direction,
            tmin,
            tmax,
            0.0f,                     // rayTime
            (mask),
            OPTIX_RAY_FLAG_DISABLE_ANYHIT,
            RAY_TYPE_RADIANCE,        // SBT offset
            RAY_TYPE_COUNT,           // SBT stride
            RAY_TYPE_RADIANCE,        // missSBTIndex
            u0, u1);
}


static __forceinline__ __device__ void traceOcclusionMasked(
        OptixTraversableHandle handle,
        float3                 ray_origin,
        float3                 ray_direction,
        float                  tmin,
        float                  tmax,
        uint8_t                mask,
        RadiancePRD           *prd)
{
    unsigned int u0, u1;
    packPointer( prd, u0, u1 );

    optixTrace(
        handle,
        ray_origin,
        ray_direction,
        tmin,
        tmax,
        0.0f,  // rayTime
        (mask),
        OPTIX_RAY_FLAG_TERMINATE_ON_FIRST_HIT,  //OPTIX_RAY_FLAG_NONE,
        RAY_TYPE_OCCLUSION,      // SBT offset
        RAY_TYPE_COUNT,          // SBT stride
        RAY_TYPE_OCCLUSION,      // missSBTIndex
        u0, u1);
}

// ----------------------------------------------------------------------------
// Volume programs
// ----------------------------------------------------------------------------

inline __device__ void confine( const nanovdb::BBox<nanovdb::Coord> &bbox, nanovdb::Vec3f &iVec )
{
    // NanoVDB's voxels and tiles are formed from half-open intervals, i.e.
    // voxel[0, 0, 0] spans the set [0, 1) x [0, 1) x [0, 1). To find a point's voxel,
    // its coordinates are simply truncated to integer. Ray-box intersections yield
    // pairs of points that, because of numerical errors, fall randomly on either side
    // of the voxel boundaries.
    // This confine method, given a point and a (integer-based/Coord-based) bounding
    // box, moves points outside the bbox into it. That means coordinates at lower
    // boundaries are snapped to the integer boundary, and in case of the point being
    // close to an upper boundary, it is move one EPS below that bound and into the volume.

    // get the tighter box around active values
    auto iMin = nanovdb::Vec3f( bbox.min() );
    auto iMax = nanovdb::Vec3f( bbox.max() ) + nanovdb::Vec3f( 1.0f );

    // move the start and end points into the bbox
    float eps = 1e-7f;
    if( iVec[0] < iMin[0] ) iVec[0] = iMin[0];
    if( iVec[1] < iMin[1] ) iVec[1] = iMin[1];
    if( iVec[2] < iMin[2] ) iVec[2] = iMin[2];
    if( iVec[0] >= iMax[0] ) iVec[0] = iMax[0] - fmaxf( 1.0f, fabsf( iVec[0] ) ) * eps;
    if( iVec[1] >= iMax[1] ) iVec[1] = iMax[1] - fmaxf( 1.0f, fabsf( iVec[1] ) ) * eps;
    if( iVec[2] >= iMax[2] ) iVec[2] = iMax[2] - fmaxf( 1.0f, fabsf( iVec[2] ) ) * eps;
}

inline __hostdev__ void confine( const nanovdb::BBox<nanovdb::Coord> &bbox, nanovdb::Vec3f &iStart, nanovdb::Vec3f &iEnd )
{
    confine( bbox, iStart );
    confine( bbox, iEnd );
}

template<typename AccT>
inline __device__ float transmittanceHDDA(
    const nanovdb::Vec3f& start,
    const nanovdb::Vec3f& end,
    AccT& acc, const float opacity )
{

    // transmittance along a ray through the volume is computed by
    // taking the negative exponential of volume's density integrated
    // along the ray.
    float transmittance = 1.f;
    auto dir = end - start;
    auto len = dir.length();
    nanovdb::Ray<float> ray( start, dir / len, 0.0f, len );
    nanovdb::Coord ijk = nanovdb::RoundDown<nanovdb::Coord>( ray.start() ); // first hit of bbox

    // Use NanoVDB's HDDA line digitization for fast integration.
    // This algorithm (http://www.museth.org/Ken/Publications_files/Museth_SIG14.pdf)
    // can skip over sparse parts of the data structure.
    //
    nanovdb::HDDA<nanovdb::Ray<float> > hdda( ray, acc.getDim( ijk, ray ) );

    float t = 0.0f;
    float density = acc.getValue( ijk ) * opacity;
    while( hdda.step())
    {
        float dt = hdda.time() - t; // compute length of ray-segment intersecting current voxel/tile
        transmittance *= expf( -density * dt );
        t = hdda.time();
        ijk = hdda.voxel();

        density = acc.getValue( ijk ) * opacity;
        hdda.update( ray, acc.getDim( ijk, ray ) ); // if necessary adjust DDA step size
    }

    return transmittance;
}


extern "C" __global__ void __intersection__volume()
{
    RadiancePRD* prd = getPRD();
    if(prd->volumeHitSurface==false)
    {
        const auto* sbt_data = reinterpret_cast<const HitGroupData*>( optixGetSbtDataPointer() );
        const nanovdb::FloatGrid* grid = reinterpret_cast<const nanovdb::FloatGrid*>(
            sbt_data->densityGrid );
        assert( grid );

        // compute intersection points with the volume's bounds in index (object) space.
        const float3 ray_orig = optixGetObjectRayOrigin();
        const float3 ray_dir  = optixGetObjectRayDirection();

        auto bbox = grid->indexBBox();
        float t0 = optixGetRayTmin();
        float t1 = optixGetRayTmax();
        auto iRay = nanovdb::Ray<float>( reinterpret_cast<const nanovdb::Vec3f&>( ray_orig ),
            reinterpret_cast<const nanovdb::Vec3f&>( ray_dir ), t0, t1 );
    
        if( iRay.intersects( bbox, t0, t1 )) // t0 >= 0
        {
            // report the exit point via payload
            getPRD()->t1 = t1; //optixSetPayload_0( __float_as_uint( t1 ) );
            // report the entry-point as hit-point
            //auto kind = optixGetHitKind();
            optixReportIntersection( fmaxf( t0, optixGetRayTmin() ), 0);
        }
    }
}

template <typename T>
inline __device__ T __Lerp(float t, T s1, T s2) {
    return (1 - t) * s1 + t * s2;
    //return fma(t, s2, fma(-t, s1, s1));
}

template <typename Acc>
inline __device__ float linearSampling(Acc& acc, nanovdb::Vec3f& test_point_indexd) {

    auto test_point_floor = nanovdb::RoundDown<nanovdb::Vec3f>(test_point_indexd);

    auto delta = test_point_indexd - test_point_floor; 

    auto point_a = nanovdb::Coord(test_point_floor[0], test_point_floor[1], test_point_floor[2]);

        auto value_000 = acc.getValue(point_a);
        auto value_100 = acc.getValue(point_a + nanovdb::Coord(1, 0, 0));

        auto value_010 = acc.getValue(point_a + nanovdb::Coord(0, 1, 0));
        auto value_110 = acc.getValue(point_a + nanovdb::Coord(1, 1, 0));

        auto value_001 = acc.getValue(point_a + nanovdb::Coord(0, 0, 1));
        auto value_101 = acc.getValue(point_a + nanovdb::Coord(1, 0, 1));

        auto value_011 = acc.getValue(point_a + nanovdb::Coord(0, 1, 1));
        auto value_111 = acc.getValue(point_a + nanovdb::Coord(1, 1, 1));

        auto value_00 = __Lerp(delta[0], value_000, value_100);
        auto value_10 = __Lerp(delta[0], value_010, value_110);
        auto value_01 = __Lerp(delta[0], value_001, value_101);
        auto value_11 = __Lerp(delta[0], value_011, value_111);
        
        auto value_0 = __Lerp(delta[1], value_00, value_10);
        auto value_1 = __Lerp(delta[1], value_01, value_11);

    return __Lerp(delta[2], value_0, value_1);
}

const static float temperatureOffset = 0;
const static float temperatureScale = 100.0;

__device__
float3 leVDB(const HitGroupData* sbt_data, nanovdb::Vec3f& point) {
    if (!sbt_data->tempGrid) 
        return make_float3(0);

    const auto* grid = reinterpret_cast<const nanovdb::FloatGrid*>(sbt_data->tempGrid );
    const auto& acc = grid->tree().getAccessor();

    auto temp = linearSampling(acc, point);
        // using Sampler = nanovdb::SampleFromVoxels<nanovdb::FloatGrid::TreeType, 1, false>;
        // Float temp = Sampler(temperatureFloatGrid->tree())(pIndex);
    temp = (temp - temperatureOffset) * temperatureScale;
    if (temp < 100) 
       return make_float3(0);

    return BlackbodySpectrum(temp).Sample(lambdaRGB);
}

extern "C" __global__ void __closesthit__radiance_volume()
{
    RadiancePRD* prd = getPRD();
    if(prd->is_test_ray==true)
        return;
    //prd->attenuation2 = prd->attenuation;
    prd->radiance = make_float3(0,0,0);

    const HitGroupData* sbt_data = reinterpret_cast<HitGroupData*>( optixGetSbtDataPointer() );

    const auto* grid = reinterpret_cast<const nanovdb::FloatGrid*>(sbt_data->densityGrid );
    const auto& acc = grid->tree().getAccessor();

    float3 ray_orig = optixGetWorldRayOrigin();
    float3 ray_dir  = optixGetWorldRayDirection();

    float t0 = optixGetRayTmax(); // world space
    float t1 = prd->t1; //__uint_as_float( optixGetPayload_0() );

    RadiancePRD testPRD;
    testPRD.t1 = 1e17f;
    testPRD.is_test_ray = true;
    //prd->is_test_ray = true;
    traceRadianceMasked(
        params.handle,
        ray_orig,
        ray_dir,
        0,
        t1,
        1,
        &testPRD);

    bool surface_inside_volume = false;
    if(testPRD.t1 < t1)
    {
        t1 = testPRD.t1;
        surface_inside_volume = true;
    }

    const float t_max = t1 - t0; // world space
    float t_ele = 0;

    auto test_point = ray_orig; 
    float3 emitting = make_float3(0.0);
    float3 scattering = make_float3(1.0);
   
    float v_density = 0.0;

#if (!_DELTA_TRACKING_) 

    auto sigma_t = (sbt_data->sigma_a + sbt_data->sigma_s);
    t_ele -= log(1 - rnd(prd->seed)) / 0.1;
    float test_t = t0 + t_ele;
    if(test_t > t1)
    {
        test_t = t1;
        if(surface_inside_volume){
            test_t = t1 - 2e-5;
            prd->volumeHitSurface = true;
        }
    }

    test_point = ray_orig + test_t * ray_dir;
    auto test_point_indexd = grid->worldToIndexF(reinterpret_cast<const nanovdb::Vec3f&>(test_point));
    v_density = linearSampling(acc, test_point_indexd);
    
    vec3 new_dir = ray_dir;
    
    if(v_density > 0){
        const auto ray = nanovdb::Ray<float>( reinterpret_cast<const nanovdb::Vec3f&>( ray_orig ),
                                              reinterpret_cast<const nanovdb::Vec3f&>( ray_dir ) );
        auto start = grid->worldToIndexF( ray( t0 ) );
        auto end   = grid->worldToIndexF( ray( test_t ) );

        auto bbox = grid->indexBBox();
        confine( bbox, start, end );

        const float opacity = sbt_data->opacityHDDA;
        
        //scattering *= transmittanceHDDA( start, end, acc, 0.01 );;
        new_dir = DisneyBSDF::SampleScatterDirection(prd->seed);

        HenyeyGreenstein hg {sbt_data->greenstein};
        float3 new_dir; float2 uu = {rnd(prd->seed), rnd(prd->seed)};
        auto pdf = hg.Sample_p(-ray_dir,             new_dir, uu);
        // //scattering *= pdf;

        scattering *= sbt_data->colorVDB;        
        ray_dir = (prd->volumeHitSurface )? ray_dir : float3(new_dir);
    }

#else

    int8_t level = 4;
    while(true) {

        auto prob = rnd(prd->seed);
        auto sigma_t = sbt_data->sigma_a + sbt_data->sigma_s;

        t_ele -= log(1 - prob) / sigma_t;

        if (t_ele >= t_max) {

            float t_tmp = t_max + surface_inside_volume? -1e-6 : 1e-6;
            test_point = ray_orig + (t0+t_ele) * ray_dir;
            break;
        } // over shoot, outside of volume

        test_point = ray_orig + (t0+t_ele) * ray_dir;

        auto test_point_indexd = grid->worldToIndexF(reinterpret_cast<const nanovdb::Vec3f&>(test_point));

        // using Sampler = nanovdb::SampleFromVoxels<nanovdb::FloatGrid::AccessorType, 1, false>;
        // float d = Sampler(acc)(test_point_indexd);

        //nanovdb::BaseStencil<typename DerivedType, int SIZE, typename GridT>
        //auto bs = nanovdb::BoxStencil<nanovdb::FloatGrid*>(grid);

        v_density = linearSampling(acc, test_point_indexd);

        if (rnd(prd->seed) < v_density) {

            HenyeyGreenstein hg {sbt_data->greenstein}; 
            
            float3 new_dir; 
            float2 uu = {rnd(prd->seed), rnd(prd->seed)};
            auto pdf = hg.Sample_p(ray_dir, new_dir, uu);

            scattering = make_float3(sbt_data->sigma_s / sigma_t);
            scattering *= sbt_data->colorVDB;

                auto le = leVDB(sbt_data, test_point_indexd);
                le *= 1000 * sbt_data->sigma_a / sigma_t;
                emitting = le * scattering;

            scattering *= emitting;

            ray_orig = test_point;
            ray_dir = new_dir;
            break;

        } else { v_density = 0; } 
    }

#endif // _DELTA_TRACKING_

    ray_orig = test_point;

    //prd->emission = emitting;
    prd->attenuation *= scattering;
    //prd->attenuation2 *= scattering;
    prd->origin = ray_orig;
    prd->direction = ray_dir;

    prd->radiance = make_float3(0.0f,0.0f,0.0f);
    float3 light_attenuation = make_float3(1.0f,1.0f,1.0f);
    float pl = rnd(prd->seed);
    float sum = 0.0f;
    for(int lidx=0;lidx<params.num_lights;lidx++)
    {
            ParallelogramLight light = params.lights[lidx];
            float3 light_pos = light.corner + light.v1 * 0.5 + light.v2 * 0.5;

            // Calculate properties of light sample (for area based pdf)
            float Ldist = length(light_pos - test_point);
            float3 L = normalize(light_pos - test_point);
            float nDl = 1.0f;//clamp(dot(N, L), 0.0f, 1.0f);
            float LnDl = clamp(-dot(light.normal, L), 0.000001f, 1.0f);
            float A = length(cross(params.lights[lidx].v1, params.lights[lidx].v2));
            sum += length(light.emission)  * nDl * LnDl * A / (M_PIf * Ldist * Ldist);

    }
    if(rnd(prd->seed)<=0.5) {
        bool computed = false;
        float ppl = 0;
        for (int lidx = 0; lidx < params.num_lights && computed == false; lidx++) {
            ParallelogramLight light = params.lights[lidx];
            float2 z = sobolRnd2(prd->seed);
            const float z1 = z.x;
            const float z2 = z.y;
            float3 light_tpos = light.corner + light.v1 * 0.5 + light.v2 * 0.5;
            float3 light_pos = light.corner + light.v1 * z1 + light.v2 * z2;

            // Calculate properties of light sample (for area based pdf)
            float tLdist = length(light_tpos - test_point);
            float3 tL = normalize(light_tpos - test_point);
            float tnDl = 1.0f; //clamp(dot(N, tL), 0.0f, 1.0f);
            float tLnDl = clamp(-dot(light.normal, tL), 0.000001f, 1.0f);
            float tA = length(cross(params.lights[lidx].v1, params.lights[lidx].v2));
            ppl += length(light.emission) * tnDl * tLnDl * tA / (M_PIf * tLdist * tLdist) / sum;
            if (ppl > pl) {
                float Ldist = length(light_pos - test_point) + 1e-6;
                float3 L = normalize(light_pos - test_point);
                float nDl = 1.0f; //clamp(dot(N, L), 0.0f, 1.0f);
                float LnDl = clamp(-dot(light.normal, L), 0.0f, 1.0f);
                float A = length(cross(params.lights[lidx].v1, params.lights[lidx].v2));
                float weight = 0.0f;
                if (nDl > 0.0f && LnDl > 0.0f) {

//                    RadiancePRD shadow_prd;
//                    shadow_prd.shadowAttanuation = make_float3(1.0f, 1.0f, 1.0f);
//                    shadow_prd.nonThinTransHit = (thin == false && specTrans > 0) ? 1 : 0;
//                    traceOcclusion(params.handle, P, L,
//                                   1e-5f,         // tmin
//                                   Ldist - 1e-5f, // tmax,
//                                   &shadow_prd);

                    //light_attenuation = shadow_prd.shadowAttanuation;
                    //if (fmaxf(light_attenuation) > 0.0f) {

                        weight = sum * nDl / tnDl * LnDl / tLnDl * (tLdist * tLdist) / (Ldist * Ldist) /
                                 (length(light.emission)+1e-6f);
                    //}
                }
                prd->LP = test_point;
                prd->Ldir = L;
                prd->nonThinTransHit = 1;
                prd->Lweight = weight;

                float3 lbrdf = make_float3(1.0) ;

                prd->radiance = 2.0 * light.emission * lbrdf;
                computed = true;
            }
        }
    } else {
        RadiancePRD shadow_prd2;
        float3 lbrdf;
        vec3 env_dir;
        bool inside = false;

        vec3 sunLightDir = vec3(params.sunLightDirX, params.sunLightDirY, params.sunLightDirZ);
        auto sun_dir = BRDFBasics::halfPlaneSample(prd->seed, sunLightDir,
                                                   params.sunSoftness * 0.2); //perturb the sun to have some softness
        sun_dir = normalize(sun_dir);
        prd->LP = test_point;
        prd->Ldir = sun_dir;
        prd->nonThinTransHit = 1;
        prd->Lweight = 1.0;
//        shadow_prd2.shadowAttanuation = make_float3(1.0f, 1.0f, 1.0f);
//        shadow_prd2.nonThinTransHit = (thin == false && specTrans > 0) ? 1 : 0;
//        traceOcclusion(params.handle, P, sun_dir,
//                       1e-5f, // tmin
//                       1e16f, // tmax,
//                       &shadow_prd2);
        lbrdf = make_float3(1.0) ;
        prd->radiance = 2.0 * float3(envSky(sun_dir, sunLightDir, make_float3(0., 0., 1.),
                                       10, // be careful
                                       .45, 15., 1.030725 * 0.3, params.elapsedTime)) * lbrdf;
    }
    //prd->emission =  make_float3(0);
    prd->CH = 1.0;
    prd->radiance *= v_density>0?1:0;
    prd->depth += v_density>0?1:0;
    return;
}

extern "C" __global__ void __anyhit__occlusion_volume()
{
    const HitGroupData* sbt_data = ( HitGroupData* )optixGetSbtDataPointer();

    const auto* grid = reinterpret_cast<const nanovdb::FloatGrid*>( sbt_data->densityGrid );
    const auto& acc = grid->tree().getAccessor();

    const float3 ray_orig = optixGetWorldRayOrigin();
    const float3 ray_dir  = optixGetWorldRayDirection();

    RadiancePRD* prd = getPRD();

    const float t0 = optixGetRayTmax();
    const float t1 = prd->t1; //__uint_as_float( optixGetPayload_0() );

    const float t_max = t1 - t0; // world space
          float t_ele = 0;

    auto test_point = ray_orig; 
    float3 transmittance = make_float3(1.0f);

#if (!_DELTA_TRACKING_) 

    const auto ray = nanovdb::Ray<float>( reinterpret_cast<const nanovdb::Vec3f&>( ray_orig ),
                                              reinterpret_cast<const nanovdb::Vec3f&>( ray_dir ) );
    auto start = grid->worldToIndexF( ray( t0 ) );
    auto end   = grid->worldToIndexF( ray( t1 ) );

    auto bbox = grid->indexBBox();
    confine( bbox, start, end );

    const float opacity = sbt_data->opacityHDDA;
    float transHDDA = transmittanceHDDA( start, end, acc, sbt_data->opacityHDDA );
    if (transHDDA < 1.0) {
        transmittance *= transHDDA;
        transmittance *= sbt_data->colorVDB;
    }

#else
    int32_t level = 0;
    while(++level<16) {

        auto prob = rnd(prd->seed);
        auto sigma_t = (sbt_data->sigma_a + sbt_data->sigma_s);

        t_ele -= log(1 - prob) / sigma_t;

        test_point = ray_orig + (t0+t_ele) * ray_dir;

        if (t_ele >= t_max) {
            break;
        } // over shoot, outside of volume

        //ray_orig = test_point;

        auto test_point_indexd = grid->worldToIndexF(reinterpret_cast<const nanovdb::Vec3f&>(test_point));
        auto v_final = linearSampling(acc, test_point_indexd);

        transmittance *= 1 - max(0.0, v_final);

        // if (_transmittance < 0.1) {
        //     float q = max(0.05, 1 - _transmittance);
        //     if (rnd(prd->seed) < q) { _transmittance = 0; }
        //     _transmittance /= 1-q;
        // }
        if (v_final > 0) {
            transmittance *= sbt_data->colorVDB;
        }
    }
#endif

    prd->shadowAttanuation *= transmittance;
    optixIgnoreIntersection();
    //prd->origin = ray_orig;
    //prd->direction = ray_dir;
    return;
}
