module main;

import std.stdio;
import std.math;
import std.typecons;
import std.complex;

import dplug.core.nogc;
import dplug.core.alignedbuffer;
import dplug.dsp.fft;
import dplug.dsp.window;
import dplug.dsp.envelope;
import dplug.dsp.smooth;
import dplug.core.math;
import gfm.sdl2;
import gfm.opengl;
import gfm.math;
import gfm.logger;
import waved;
 

void usage()
{
    writeln("usage: fft-visualizer <input-file>");
}

// TODO: plot phase derivative instead of phase

int main(string[] args)
{
    if (args.length != 2)
    {
        usage;
        return 1;
    }
    string inputFile = args[1];

    // Load sound
    writefln("Loading %s...", inputFile);
    const(Sound) inputSound = decodeSound(inputFile).makeMono;
    
    int width = 1280;
    int height = 720;
    double ratio = width / cast(double)height;

    // load dynamic libraries
    auto logger = scoped!ConsoleLogger();
    auto sdl2 = scoped!SDL2(logger, SharedLibVersion(2, 0, 0));
    auto gl = scoped!OpenGL(logger);

    // You have to initialize each SDL subsystem you want by hand
    sdl2.subSystemInit(SDL_INIT_VIDEO);
    sdl2.subSystemInit(SDL_INIT_EVENTS);

    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);

    // create an OpenGL-enabled SDL window
    auto window = scoped!SDL2Window(sdl2,
                                    SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
                                    width, height,
                                    SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_SHOWN);
    window.setTitle("fft-visualizer " ~ inputFile);

    gl.reload(GLVersion.None, GLVersion.GL33);
    gl.redirectDebugOutput();

    auto program = scoped!GLProgram(gl, blitShaderSource);

    struct LinePoint
    {
        vec4f position;
        vec4f color;
    }

    auto linePointsVBO = scoped!GLBuffer(gl, GL_ARRAY_BUFFER, GL_DYNAMIC_DRAW);
    // Create an OpenGL vertex description from the Vertex structure.
    auto linePointsVS = new VertexSpecification!LinePoint(program);
    auto linePointsVAO = scoped!GLVAO(gl);
    
    // prepare VAO
    {
        linePointsVAO.bind();
        linePointsVBO.bind();
        linePointsVS.use();
        linePointsVAO.unbind();
    }    

    uint lastTime = SDL_GetTicks();

    AlignedBuffer!LinePoint linePoints = makeAlignedBuffer!LinePoint();   

    FFTAnalyzer!double analyzer;
    
    float sampleRate = inputSound.sampleRate;
    float currentPositionInSamples = 0;
    float currentAngle = 0;
    bool compensateNormalPhaseIncrease = true;
    WindowType windowType = WindowType.KAISER_BESSEL;

    // Analyze audio
    int analysisWindowSize = 1024;
    int fftOversampling = 2;

    auto fftData = makeAlignedBuffer!(Complex!double)();

    auto magnitudes = makeAlignedBuffer!float();
    auto spectralEnv = makeAlignedBuffer!float();
    auto phases = makeAlignedBuffer!float();
    auto currentSamples = makeAlignedBuffer!float();
  
    float maxAbs = -float.infinity;
    float minAbs = float.infinity;

    while(!sdl2.keyboard.isPressed(SDLK_ESCAPE))
    {
        // compute delta time
        uint now = SDL_GetTicks();
        double dt = (now - lastTime)/1000.0;
        lastTime = now;

        sdl2.processEvents();

        with(sdl2.keyboard)
        {
            bool shift = isPressed(SDLK_LSHIFT) || isPressed(SDLK_RSHIFT);
            bool ctrl = isPressed(SDLK_LCTRL) || isPressed(SDLK_RCTRL);
            bool isLeft = isPressed(SDLK_LEFT);
            bool isRight = isPressed(SDLK_RIGHT);
            if (testAndRelease(SDLK_p))
                compensateNormalPhaseIncrease = !compensateNormalPhaseIncrease;
            if (testAndRelease(SDLK_w))
            {
                if (shift)
                {
                    windowType--;
                    if (windowType < WindowType.min)
                        windowType = WindowType.max;
                }
                else
                {
                    windowType++;
                    if (windowType > WindowType.max)
                        windowType = WindowType.min;
                }
            }
            if (isRight)
            {
                if (shift && ctrl)
                {
                    testAndRelease(SDLK_RIGHT);
                    currentPositionInSamples += (analysisWindowSize/4);
                }
                else if (shift)
                {
                    testAndRelease(SDLK_RIGHT);
                    currentPositionInSamples += 1;
                }
                else if (ctrl)
                {
                    currentPositionInSamples += sampleRate * dt;
                }
                else
                    currentPositionInSamples += 1000 * dt;
            }

            if (isLeft)
            {
                if (shift && ctrl)
                {
                    testAndRelease(SDLK_RIGHT);
                    currentPositionInSamples -= (analysisWindowSize/4);
                }
                else if (shift)
                {
                    testAndRelease(SDLK_LEFT);
                    currentPositionInSamples -= 1;
                }
                else if (ctrl)
                {
                    currentPositionInSamples -= sampleRate * dt;
                }
                else
                    currentPositionInSamples -= 1000 * dt;
            }
            if (isPressed(SDLK_UP))
                currentAngle += dt;
            if (isPressed(SDLK_DOWN))
                currentAngle -= dt;
        }

        int fftSize = analysisWindowSize * fftOversampling;

        // reinitialize analyzer each frame
        // no overlap of course
        analyzer.initialize(analysisWindowSize, fftSize, analysisWindowSize, WindowDesc(windowType, 2.5f), false); 
        fftData.resize(fftSize);

        // fetch enough data for one frame of analysis, at the end it should return FFT data
        currentSamples.clearContents();
        for (int i = 0; i < analysisWindowSize; ++i)
        {
            float input;
            int pos = i + cast(int)currentPositionInSamples;
            if (pos >= 0 && pos < inputSound.lengthInFrames())
                input = inputSound.sample(0, pos);
            else
                input = 0;

            currentSamples.pushBack(input);
        }

        for (int i = 0; i < analysisWindowSize; ++i)
        {
            bool hasData = analyzer.feed(currentSamples[i], fftData[]);
            assert(hasData == (i+1 == analysisWindowSize));
        }

        // clear the whole window
        SDL_Point windowSize = window.getSize();
        glViewport(0, 0, windowSize.x, windowSize.y);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);


        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE); // additive
        glHint(GL_LINE_SMOOTH_HINT, GL_NICEST);

        // here fftData holds fftSize bins
        {
            // fill magnitude and phases
            magnitudes.clearContents();
            phases.clearContents();           
            spectralEnv.clearContents();

            // draw one line for each FFT bin
            
            for (int i = 0; i < fftSize/2+1; ++i)
            {
                double phase = fftData[i].arg;

                // Compensate for "normal" phase gain
                if (compensateNormalPhaseIncrease)
                {
                    phase -= 2 * PI * (cast(int)currentPositionInSamples * i) / cast(double)fftSize;
                }
                phases.pushBack(phase);
                float mag = floatToDeciBel( abs(fftData[i]) );
                if (mag < -100)
                    mag = -100;
                if (maxAbs < mag)
                    maxAbs = mag;
                if (minAbs > mag)
                    minAbs = mag;
                magnitudes.pushBack(mag);
            }


            float globalAlpha = 1.4f * windowSize.x / cast(float)fftSize;
            if (globalAlpha > 1)
                globalAlpha = 1;
            linePoints.clearContents();

            // Add time domain points
            for (int i = 0; i + 1 < analysisWindowSize; ++i)
            {
                float posx = -0.9 + (1.8 * i) / analysisWindowSize;
                vec4f color = vec4f(1, 1, 1, 1.0);
                linePoints.pushBack( LinePoint( vec4f(posx, currentSamples[i] - 0.7, 0, 1), color ) );
                linePoints.pushBack( LinePoint( vec4f(posx, currentSamples[i+1] - 0.7, 0, 1), color ) );
            }

            float ZOOM = 10.8f;

            // 3D lines (phase display)
            for (int i = 0; i < fftSize /2+1; i += 1)
            {
                float mag = magnitudes[i];
                float alpha = linmap!float(mag, minAbs, maxAbs, 0, 1);

                float frequency = (sampleRate * i) / fftSize;
                float posx = -0.9 + ZOOM * (i / (fftSize/2.0));// * log(1 + frequency) / 4.6;
                float phase = phases[i] + currentAngle;
                float extent = 1.0 / maxAbs;
                float posy = alpha * cos(phase);
                float posz = alpha * sin(phase);

                vec4f color = vec4f(0.5 + cos(i*0.01f)*0.5, 
                                    0.5 - cos(i*0.01f)*0.5,
                                    (i&1) ? 0.5f :1.0f, globalAlpha * (0.2 + 0.8 * alpha));

                linePoints.pushBack( LinePoint( vec4f(posx, 0, 0, 1), color ) );
                linePoints.pushBack( LinePoint( vec4f(posx,posy,posz,1), color ) );
            }

            // unwrapped phase display
            for (int i = 1; i < fftSize /2; i += 1)
            {
                float pA = normalizePhase(phases[i+1]-phases[i]);
                float pB = normalizePhase(phases[i]-phases[i-1]);

                float posA = -0.9 + ZOOM * ((i+1) / (fftSize/2.0));
                float posB = -0.9 + ZOOM * ((i) / (fftSize/2.0));
                

                vec4f color = vec4f(1, 1, 0, 1);
                linePoints.pushBack( LinePoint( vec4f(posA, 0.5f*pA/PI, 0, 1), color ) );
                linePoints.pushBack( LinePoint( vec4f(posB, 0.5f*pB/PI, 0, 1), color ) );
            }

            // spectrum outline
            for (int i = 0; i < fftSize/2; ++i)
            {
                float posxA = -0.9 + 10.8 * (i / (fftSize/2.0));
                float posxB = -0.9 + 10.8 * ((i+1) /(fftSize/2.0));
                float alphaA = linmap!float(magnitudes[i], minAbs, maxAbs, 0, 1);
                float alphaB = linmap!float(magnitudes[i+1], minAbs, maxAbs, 0, 1);

                bool isPeak = false;
                if (i >= 2 && (i + 2 < fftSize/2))
                {
                    isPeak = ( magnitudes[i] > magnitudes[i+1])
                          && ( magnitudes[i+1] > magnitudes[i+2])
                          && ( magnitudes[i] > magnitudes[i-1])
                          && ( magnitudes[i-1] > magnitudes[i-2]);
                }

                float fPeak = isPeak ? 1 : 0;
                vec4f colorA = vec4f(1, fPeak, fPeak, alphaA);
                vec4f colorB = vec4f(1, fPeak, fPeak, alphaB);

                linePoints.pushBack( LinePoint( vec4f(posxA,alphaA,0,1), globalAlpha*colorA ) );
                linePoints.pushBack( LinePoint( vec4f(posxB,alphaB,0,1), globalAlpha*colorB ) );
            }

            // compute spectral envelope for testing formant preservation ideas
            {
                for (int i = 0; i < fftSize/2; ++i)
                {
                    spectralEnv.pushBack(magnitudes[i]);
                }

                UnstableMeanFilter!float mean;
                
                int L = 40;
                mean.initialize(0, L);

                foreach(i; 0..L/2)
                    mean.nextSample(magnitudes[0]);

                foreach(i; 0..L/2)
                    mean.nextSample(magnitudes[i]);

                for (int i = 0; i < fftSize/2+1; ++i)
                {
                    float inp = (i+L/2 < fftSize/2) ? (magnitudes[i+L/2]) : magnitudes[fftSize/2];
                    spectralEnv[i] = mean.nextSample(inp);
                }
                

                for (int i = 0; i < fftSize/2; ++i)
                {
                    float posxA = -0.9 + 1.8 * (i / (fftSize/2.0));
                    float posxB = -0.9 + 1.8 * (i / (fftSize/2.0));

                    float alphaA = linmap!float(spectralEnv[i], minAbs, maxAbs, 0, 1);
                    float alphaB = linmap!float(spectralEnv[i+1], minAbs, maxAbs, 0, 1);

                    vec4f colorA = vec4f(0, 1, 0, 1);
                    vec4f colorB = vec4f(0, 1, 0, 1);

                    linePoints.pushBack( LinePoint( vec4f(posxA,alphaA,0,1), globalAlpha*colorA ) );
                    linePoints.pushBack( LinePoint( vec4f(posxB,alphaB,0,1), globalAlpha*colorB ) );
                }
            }
        }


        mat4d projection =
            //mat4d.perspective(1, windowSize.x / cast(float)windowSize.y, 0.1f, 100) *
            mat4d(1, 0, 0.1, 0,
                  0, 1, -0.1, 0,
                  0, 0, 1, 0,
                  0, 0, 0, 1);

            

    //    vec3d eye = vec3f(0, 0, 2);
       // vec3d target = vec3f(0, 0, 0);
     //   vec3d up = vec3f(0, 1, 0);
       // mat4d view = mat4d.lookAt(eye, target, up);
        mat4d model = mat4d.identity;

        mat4f MVP =  cast(mat4f)(projection);
        program.uniform("mvpMatrix").set(MVP);
        program.use();

        linePointsVBO.setData(linePoints[]);

        // draw FFT points
        {
            linePointsVAO.bind();
            glDrawArrays(GL_LINES, 0, cast(int)(linePointsVBO.size() / linePointsVS.vertexSize()));
            linePointsVAO.unbind();
        }
        program.unuse();

        window.swapBuffers();
    }
    return 0;
}

static immutable string blitShaderSource =
q{#version 330 core

    #if VERTEX_SHADER
    in vec4 position;
    in vec4 color;
    out vec4 fColor;
    uniform mat4 mvpMatrix;
    void main()
    {
        gl_Position = mvpMatrix * vec4(position.xyz, 1.0);
        fColor = color;
    }
    #endif

    #if FRAGMENT_SHADER
    in vec4 fColor;
    out vec4 fragColor;

    void main()
    {                
        fragColor = fColor;
    }
    #endif
};