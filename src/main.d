module main;

import std.stdio;
import std.math;
import std.typecons;
import std.complex;

//import derelict.util.loader;
import dplug.core.nogc;
import dplug.core.alignedbuffer;
import dplug.dsp.fft;
import dplug.dsp.window;
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

    gl.reload();
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

    FFTAnalyzer analyzer;
    
    float sampleRate = inputSound.sampleRate;
    float currentPositionInSamples = 0;
    float currentAngle = 0;

    // Analyze audio
    int analysisWindowSize = 1024;
    int fftOversampling = 1;


    auto fftData = makeAlignedBuffer!(Complex!float)();
    

    while(!sdl2.keyboard.isPressed(SDLK_ESCAPE))
    {
        // compute delta time
        uint now = SDL_GetTicks();
        double dt = (now - lastTime)/1000.0;
        lastTime = now;

        sdl2.processEvents();

        with(sdl2.keyboard)
        {
            if (isPressed(SDLK_RIGHT))
                currentPositionInSamples += sampleRate * dt;
            if (isPressed(SDLK_LEFT))
                currentPositionInSamples -= sampleRate * dt;     
            if (isPressed(SDLK_UP))
                currentAngle += dt;
            if (isPressed(SDLK_DOWN))
                currentAngle -= dt;
        }

        int fftSize = analysisWindowSize * fftOversampling;

        // reinitialize analyzer each frame
        // no overlap of course
        analyzer.initialize(analysisWindowSize, fftSize, analysisWindowSize, WindowType.HANN, false); 
        fftData.resize(fftSize);

        // fetch enough data for one frame of analysis, at the end it should return FFT data
        for (int i = 0; i < analysisWindowSize; ++i)
        {
            float input;
            int pos = i + cast(int)currentPositionInSamples;
            if (pos >= 0 && pos < inputSound.lengthInFrames())
                input = inputSound.sample(0, pos);
            else
                input = 0;

            bool hasData = analyzer.feed(input, fftData[]);
            assert(hasData == (i+1 == analysisWindowSize));
        }

        // here fftData holds fftSize bins
        {
            linePoints.clearContents();
            vec4f white = vec4f(1,1,1,1);

            // draw one line for each FFT bin
            for (int i = 0; i < fftSize/2+1; ++i)
            {
                float frequency = (sampleRate * i) / fftSize;
                float posx = -0.9 + 1.8 * (i / (fftSize/2.0));// * log(1 + frequency) / 4.6;
                float phase = fftData[i].arg + currentAngle;
                float extent = 1;
                float abs = (80 + floatToDeciBel( abs(fftData[i]) ) ) / 100; // TODO: normalize by largest value in frame?
                if (abs < 0)
                    abs = 0;

                float posy = abs * cos(phase);
                float posz = abs * sin(phase);


                linePoints.pushBack( LinePoint( vec4f(posx,0,0,1), white ) );
                linePoints.pushBack( LinePoint( vec4f(posx,posy,posz,1), white ) );
            }
        }

        // clear the whole window
        SDL_Point windowSize = window.getSize();
        glViewport(0, 0, windowSize.x, windowSize.y);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        mat4d projection = mat4d(1, 0, 0.1, 0,
                                 0, 1, 0.0, 0,
                                 0, 0, 1, 0,
                                 0, 0, 0, 1);

        //    perspective(1, windowSize.x / cast(float)windowSize.y, 1.0f, 100000);

        vec3d eye = vec3f(0, 0, 2);
        vec3d target = vec3f(0, 0, 0);
        vec3d up = vec3f(0, 1, 0);
        mat4d view = mat4d.lookAt(eye, target, up);
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